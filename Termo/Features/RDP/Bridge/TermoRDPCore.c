//  FreeRDP C 调用层（编译为纯 C，不含 Foundation/CoreFoundation/IOKit）。
//  把 FreeRDP/WinPR 的类型与调用全部关在本 TU 内，对外只暴露 C 基本类型（见 TermoRDPCore.h），
//  从根上避开 WinPR 的 GUID/IID/REFIID 与 CoreFoundation CFPlugInCOM/IOKit 同名 COM 类型的冲突。
//
//  连接走**底层** freerdp_new + freerdp_context_new（而非高层 freerdp_client_context_new）：
//  高层 client API 会自动加载一堆**动态虚拟通道**（rdpsnd/rdpgfx/echo/ainput…），静态内嵌构建下
//  没有 .dylib 插件可 dlopen → pre_connect 失败。基础远程桌面用 legacy GDI 帧缓冲，不需要这些通道。
#include "TermoRDPCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/event.h>
#include <freerdp/version.h>
#include <freerdp/settings.h>
#include <freerdp/addin.h>            // FREERDP_ADDIN_CHANNEL_STATIC / ENTRYEX
#include <freerdp/client/cmdline.h>   // freerdp_client_add_dynamic_channel
#include <freerdp/client/channels.h>  // freerdp_channels_load_static_addin_entry
#include <freerdp/channels/channels.h>// freerdp_channels_client_load_ex
#include <freerdp/client/disp.h>      // DispClientContext / SendMonitorLayout（动态分辨率）
#include <freerdp/channels/disp.h>    // DISP_DVC_CHANNEL_NAME / DISPLAY_CONTROL_MONITOR_LAYOUT
#include <winpr/synch.h>

// 自定义上下文：首字段必须是 rdpContext，便于在回调里 (TermoContext*)context 取回 owner。
typedef struct {
    rdpContext context;
    TermoRDPHandle *owner;
} TermoContext;

struct TermoRDPHandle {
    freerdp *instance;
    rdpContext *context;
    TermoRDPCallbacks cb;
    pthread_t thread;
    int thread_started;
    DispClientContext *disp;   // DisplayControl 通道连上后填入，用于动态分辨率
    int dynresize_ready;       // 收到 DisplayControlCaps 后才置 1，之前发 SendMonitorLayout 服务器会忽略
    UINT32 want_w, want_h;     // 最后一次请求的目标尺寸；通道未就绪时缓存，就绪后补发（消除连接期竞态）
};

static void termo_emit_state(TermoRDPHandle *h, TermoRDPState s, const char *msg) {
    if (h && h->cb.on_state) h->cb.on_state(h->cb.userdata, s, msg);
}

// ── 绘制回调 ────────────────────────────────────────────────────────────────
// BeginPaint：清空 invalid 区域标记，开始累积本帧脏区。
static BOOL termo_begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd &&
        gdi->primary->hdc->hwnd->invalid)
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

// EndPaint：把 gdi 主缓冲连同宽/高/步幅/每像素字节数交给上层拷贝渲染。
// bpp 随帧上报——服务器可能将帧格式降级为 RGB16（2 字节/像素），上层据此选 CGImage 位序，
// 避免按固定 32bpp 误读而出现行错位撕裂。
static BOOL termo_end_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary_buffer) return TRUE;
    TermoRDPHandle *h = ((TermoContext *)context)->owner;
    if (h && h->cb.on_frame)
        h->cb.on_frame(h->cb.userdata, gdi->primary_buffer, gdi->width, gdi->height,
                       (int)gdi->stride, (int)FreeRDPGetBytesPerPixel(gdi->dstFormat));
    return TRUE;
}

// DesktopResize：服务端确认分辨率变更后触发，按新尺寸重建 gdi 主缓冲（动态分辨率落地的最后一步）。
static BOOL termo_desktop_resize(rdpContext *context) {
    rdpSettings *s = context->settings;
    return gdi_resize(context->gdi, freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
                      freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight));
}

// ── DisplayControl（动态分辨率）────────────────────────────────────────────
// 向服务端发送单主显示器布局，请求远端桌面改用 width×height。返回 SendMonitorLayout 的 rc。
static UINT termo_disp_send_layout(TermoRDPHandle *h, UINT32 width, UINT32 height) {
    if (!h || !h->disp || !h->disp->SendMonitorLayout) return 0xFFFF;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    memset(&layout, 0, sizeof(layout));
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = width;
    layout.Height = height;
    layout.PhysicalWidth = width;       // 物理尺寸=逻辑尺寸，等价 DPI 100%（对齐官方客户端）
    layout.PhysicalHeight = height;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = 100;
    layout.DeviceScaleFactor = 100;
    return h->disp->SendMonitorLayout(h->disp, 1, &layout);
}

// DisplayControlCaps：服务端声明支持动态分辨率后才触发。此前发布局会被忽略，故以此为就绪信号，
// 并补发连接期缓存的目标尺寸——消除「窗口在展开过程中连接、resize 请求早于通道就绪而被丢弃」的竞态。
static UINT termo_disp_caps(DispClientContext *disp, UINT32 maxNumMonitors,
                            UINT32 maxMonitorAreaFactorA, UINT32 maxMonitorAreaFactorB) {
    (void)maxNumMonitors; (void)maxMonitorAreaFactorA; (void)maxMonitorAreaFactorB;
    TermoRDPHandle *h = disp ? (TermoRDPHandle *)disp->custom : NULL;
    if (h) {
        h->dynresize_ready = 1;
        if (h->want_w && h->want_h) termo_disp_send_layout(h, h->want_w, h->want_h);
    }
    return CHANNEL_RC_OK;
}

// disp DVC 连上 → 捕获 DispClientContext 并挂上 caps 回调，供后续发送布局。
static void termo_on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    if (!e || !e->name || strcmp(e->name, DISP_DVC_CHANNEL_NAME) != 0) return;
    TermoRDPHandle *h = ((TermoContext *)context)->owner;
    DispClientContext *disp = (DispClientContext *)e->pInterface;
    if (!h || !disp) return;
    disp->custom = h;
    disp->DisplayControlCaps = termo_disp_caps;
    h->disp = disp;
}

// ── 通道加载回调（动态分辨率的关键接入点）──────────────────────────────────
// 时序：核心在 PreConnect 之后调用 utils_reload_channels —— 它先 free 旧 channels、新建空 channels，
// 再回调 instance->LoadChannels 重新填充，最后 freerdp_channels_pre_connect 初始化静态通道。
// 因此通道必须在本回调内加载（放在 PreConnect 里会被随后的 reload 丢弃，drdynvc/disp 永远连不上）。
static BOOL termo_load_channels(freerdp *instance) {
    rdpContext *context = instance->context;
    rdpSettings *s = context->settings;

    // 注册「静态查表」为全局 addin provider。否则 drdynvc 加载 disp 子通道时走的
    // freerdp_load_channel_addin_entry 只会 dlopen libdisp-client.dylib（静态内嵌构建中不存在）→ 失败。
    // 注册后它优先查静态表 CLIENT_DVCPluginEntry_TABLE（含 disp_DVCPluginEntry），无需 dlopen。
    // 高层 client API 在 freerdp_client_common_new 中完成此步，底层路径需自行补上。
    freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0);

    // 仅手动加载 drdynvc（动态虚拟通道传输层）。disp 已在 connect 时加入动态通道列表，
    // drdynvc 协商成功后会据此从静态表拉起 disp 子通道。
    // 不用 freerdp_client_load_addins：它会一并请求 rdpdr 等未注册静态入口的通道 → 回退 dlopen 失败。
    PVIRTUALCHANNELENTRY ex = freerdp_channels_load_static_addin_entry(
        "drdynvc", NULL, NULL,
        FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX);
    if (ex) freerdp_channels_client_load_ex(context->channels, s, (PVIRTUALCHANNELENTRYEX)ex, NULL);
    return TRUE;
}

// ── 连接生命周期回调 ────────────────────────────────────────────────────────
static BOOL termo_pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    rdpSettings *s = context->settings;
    if (!freerdp_settings_set_bool(s, FreeRDP_CertificateCallbackPreferPEM, TRUE)) return FALSE;
    PubSub_SubscribeChannelConnected(context->pubSub, termo_on_channel_connected);
    return TRUE;
}

static BOOL termo_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;  // BGRX32：32bpp 无 alpha，对齐官方 Mac 客户端
    rdpContext *context = instance->context;
    context->update->BeginPaint = termo_begin_paint;
    context->update->EndPaint = termo_end_paint;
    context->update->DesktopResize = termo_desktop_resize;
    termo_emit_state(((TermoContext *)context)->owner, TermoRDPStateConnected, NULL);
    return TRUE;
}

static void termo_post_disconnect(freerdp *instance) {
    if (!instance || !instance->context) return;
    TermoRDPHandle *h = ((TermoContext *)instance->context)->owner;
    gdi_free(instance);
    termo_emit_state(h, TermoRDPStateDisconnected, NULL);
}

// 证书校验：阶段 E 接入确认 UI；当前接受本次连接（返回 1）。
static DWORD termo_verify_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                         const char *common_name, const char *subject,
                                         const char *issuer, const char *fingerprint, DWORD flags) {
    (void)instance; (void)host; (void)port; (void)common_name;
    (void)subject; (void)issuer; (void)fingerprint; (void)flags;
    return 1;
}

// ── 事件循环线程（参照 tf_freerdp.c 的 tf_client_thread_proc）────────────────
static void *termo_thread_proc(void *arg) {
    TermoRDPHandle *h = (TermoRDPHandle *)arg;
    freerdp *instance = h->instance;

    if (!freerdp_connect(instance)) {
        termo_emit_state(h, TermoRDPStateFailed, "连接失败");
        return NULL;
    }

    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
    while (!freerdp_shall_disconnect_context(h->context)) {
        DWORD nCount = freerdp_get_event_handles(h->context, handles, ARRAYSIZE(handles));
        if (nCount == 0) break;
        DWORD status = WaitForMultipleObjects(nCount, handles, FALSE, 100);
        if (status == WAIT_FAILED) break;
        if (!freerdp_check_event_handles(h->context)) break;
    }

    freerdp_disconnect(instance);
    return NULL;  // 断开态由 termo_post_disconnect 发出
}

// ── 对外 API ────────────────────────────────────────────────────────────────
const char *termo_rdp_freerdp_version(void) {
    static char buf[32];
    snprintf(buf, sizeof(buf), "%d.%d.%d",
             FREERDP_VERSION_MAJOR, FREERDP_VERSION_MINOR, FREERDP_VERSION_REVISION);
    return buf;
}

TermoRDPHandle *termo_rdp_create(TermoRDPCallbacks callbacks) {
    TermoRDPHandle *h = calloc(1, sizeof(*h));
    if (h) h->cb = callbacks;
    return h;
}

int termo_rdp_connect(TermoRDPHandle *h, const char *host, int port,
                      const char *username, const char *password,
                      const char *domain, int width, int height) {
    if (!h || !host || h->instance) return 1;

    freerdp *instance = freerdp_new();
    if (!instance) return 2;
    instance->ContextSize = sizeof(TermoContext);
    instance->PreConnect = termo_pre_connect;
    instance->LoadChannels = termo_load_channels;   // 核心 reload 后回填通道（drdynvc→disp）的唯一时机
    instance->PostConnect = termo_post_connect;
    instance->PostDisconnect = termo_post_disconnect;
    instance->VerifyCertificateEx = termo_verify_certificate_ex;

    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        return 3;
    }
    h->instance = instance;
    h->context = instance->context;
    ((TermoContext *)instance->context)->owner = h;

    rdpSettings *s = instance->context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)port);
    if (username) freerdp_settings_set_string(s, FreeRDP_Username, username);
    if (password) freerdp_settings_set_string(s, FreeRDP_Password, password);
    if (domain) freerdp_settings_set_string(s, FreeRDP_Domain, domain);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)width);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)height);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    // 动态分辨率（DisplayControl）三件套：DVC 传输 + DisplayControl 支持 + 分辨率更新，缺一则 disp 无法协商。
    freerdp_settings_set_bool(s, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE);
    // 关闭音频播放/采集：对应通道在 FreeRDP 构建中已禁用，开启会被请求 → dlopen 缺失插件而失败。
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_AudioCapture, FALSE);
    // 把 disp 加入动态通道列表，drdynvc 协商后据此拉起 DisplayControl 子通道。
    const char *disp_args[] = { "disp" };
    freerdp_client_add_dynamic_channel(s, 1, disp_args);

    termo_emit_state(h, TermoRDPStateConnecting, NULL);
    if (pthread_create(&h->thread, NULL, termo_thread_proc, h) != 0) return 4;
    h->thread_started = 1;
    return 0;
}

// ── 鼠标输入（从主线程发；用户级低频，暂不加锁，阶段 F 再做线程安全）────────
static rdpInput *termo_input(TermoRDPHandle *h) {
    return (h && h->context) ? h->context->input : NULL;
}

void termo_rdp_mouse_move(TermoRDPHandle *h, int x, int y) {
    rdpInput *in = termo_input(h);
    if (in) freerdp_input_send_mouse_event(in, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y);
}

void termo_rdp_mouse_button(TermoRDPHandle *h, int button, int down, int x, int y) {
    rdpInput *in = termo_input(h);
    if (!in) return;
    UINT16 flags;
    switch (button) {
        case 0: flags = PTR_FLAGS_BUTTON1; break;  // 左
        case 1: flags = PTR_FLAGS_BUTTON2; break;  // 右
        case 2: flags = PTR_FLAGS_BUTTON3; break;  // 中
        default: return;
    }
    if (down) flags |= PTR_FLAGS_DOWN;
    freerdp_input_send_mouse_event(in, flags, (UINT16)x, (UINT16)y);
}

void termo_rdp_mouse_wheel(TermoRDPHandle *h, int delta, int x, int y) {
    rdpInput *in = termo_input(h);
    if (!in) return;
    UINT16 flags = PTR_FLAGS_WHEEL;
    int amount = delta;
    if (amount < 0) { flags |= PTR_FLAGS_WHEEL_NEGATIVE; amount = -amount; }
    if (amount > 0xFF) amount = 0xFF;
    flags |= (UINT16)(amount & 0xFF);
    freerdp_input_send_mouse_event(in, flags, (UINT16)x, (UINT16)y);
}

void termo_rdp_resize(TermoRDPHandle *h, int width, int height) {
    if (!h || width < 1 || height < 1) return;
    // 始终记下目标尺寸。通道/能力就绪即发；否则缓存，待 DisplayControlCaps 到达由 termo_disp_caps 补发。
    h->want_w = (UINT32)width;
    h->want_h = (UINT32)height;
    if (h->dynresize_ready && h->disp)
        termo_disp_send_layout(h, (UINT32)width, (UINT32)height);
}

void termo_rdp_disconnect(TermoRDPHandle *h) {
    if (h && h->context) freerdp_abort_connect_context(h->context);
}

void termo_rdp_free(TermoRDPHandle *h) {
    if (!h) return;
    if (h->instance) {
        if (h->context) freerdp_abort_connect_context(h->context);
        if (h->thread_started) { pthread_join(h->thread, NULL); h->thread_started = 0; }
        freerdp_context_free(h->instance);
        freerdp_free(h->instance);
        h->instance = NULL;
        h->context = NULL;
    }
    free(h);
}
