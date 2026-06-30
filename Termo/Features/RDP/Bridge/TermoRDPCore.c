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
#include <freerdp/scancode.h>        // RDP_SCANCODE_*（修饰键扫描码）
#include <winpr/input.h>             // GetVirtualKeyCodeFromKeycode / GetVirtualScanCodeFromVirtualKeyCode
#include <freerdp/event.h>
#include <freerdp/version.h>
#include <freerdp/settings.h>
#include <freerdp/addin.h>            // FREERDP_ADDIN_CHANNEL_STATIC / ENTRYEX
#include <freerdp/client/cmdline.h>   // freerdp_client_add_dynamic_channel
#include <freerdp/client/channels.h>  // freerdp_channels_load_static_addin_entry
#include <freerdp/channels/channels.h>// freerdp_channels_client_load_ex
#include <freerdp/client/disp.h>      // DispClientContext / SendMonitorLayout（动态分辨率）
#include <freerdp/channels/disp.h>    // DISP_DVC_CHANNEL_NAME / DISPLAY_CONTROL_MONITOR_LAYOUT
#include <freerdp/client/cliprdr.h>   // CliprdrClientContext（剪贴板同步）
#include <freerdp/channels/cliprdr.h> // CLIPRDR_* PDU / CB_* 常量 / CLIPRDR_SVC_CHANNEL_NAME
#include <freerdp/client/rdpgfx.h>    // RdpgfxClientContext（图形管线 / 全彩）
#include <freerdp/channels/rdpgfx.h>  // RDPGFX_DVC_CHANNEL_NAME
#include <freerdp/gdi/gfx.h>          // gdi_graphics_pipeline_init/uninit
#include <winpr/user.h>               // CF_UNICODETEXT
#include <winpr/string.h>             // ConvertUtf8ToWCharAlloc / ConvertWCharNToUtf8Alloc
#include <winpr/synch.h>

#include <openssl/provider.h>        // OSSL_PROVIDER_add_builtin / OSSL_PROVIDER_load

// ── OpenSSL legacy provider（NTLM 所需的 MD4 / RC4 / DES）─────────────────────
// OpenSSL 3 把 MD4/RC4/DES 移到了 legacy provider；本工程静态内嵌 OpenSSL，legacy provider
// 不会被自动加载，导致 WinPR 的 NTLM 取不到 MD4（日志：no md4 support / SEC_E_INTERNAL_ERROR）
// → NLA 认证失败、连接断开。这里把随静态库（liblegacy.a）链接进来的 provider 入口注册为 builtin
// 并显式加载（default 一并加载兜底）。必须在任何 NTLM 加密之前（即 freerdp_connect 之前）完成。
extern OSSL_provider_init_fn ossl_legacy_provider_init;   // 由静态 liblegacy.a 导出

static void termo_openssl_register_legacy(void) {
    OSSL_PROVIDER_add_builtin(NULL, "legacy", ossl_legacy_provider_init);
    OSSL_PROVIDER_load(NULL, "legacy");
    OSSL_PROVIDER_load(NULL, "default");
}

static void termo_ensure_openssl_legacy(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, termo_openssl_register_legacy);
}

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
    int mod_state;             // 上次上报的修饰键掩码（TermoRDPModMask），用于 diff 出增量
    CliprdrClientContext *cliprdr;  // CLIPRDR 通道连上后填入，用于剪贴板同步
    WCHAR *clip_local;         // 本地剪贴板文本（UTF-16，含结尾 null），用于响应服务器取数据请求
    UINT32 clip_local_bytes;   // clip_local 字节数（含结尾 null 的 2 字节）
    RdpgfxClientContext *gfx;  // RDPGFX 图形管线（全彩）连上后填入；服务器不支持则保持 NULL、留 legacy GDI
};

static void termo_emit_state(TermoRDPHandle *h, TermoRDPState s, const char *msg) {
    if (h && h->cb.on_state) h->cb.on_state(h->cb.userdata, s, msg);
}

// 连接日志：转发给上层「实时日志」面板。level 0=信息 1=警告 2=错误。
static void termo_log(TermoRDPHandle *h, int level, const char *text) {
    if (h && h->cb.on_log && text) h->cb.on_log(h->cb.userdata, level, text);
}

// 从 freerdp 实例取回 owner 句柄（各回调里复用）。
static TermoRDPHandle *termo_owner(freerdp *instance) {
    return (instance && instance->context) ? ((TermoContext *)instance->context)->owner : NULL;
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
        termo_log(h, 0, "显示控制通道就绪（支持动态分辨率）");
        if (h->want_w && h->want_h) termo_disp_send_layout(h, h->want_w, h->want_h);
    }
    return CHANNEL_RC_OK;
}

// ── 剪贴板同步（CLIPRDR）──────────────────────────────────────────────────
// 发送客户端能力集（通用集，支持长格式名）。
static UINT termo_cliprdr_send_caps(CliprdrClientContext *c) {
    CLIPRDR_GENERAL_CAPABILITY_SET gen = { 0 };
    gen.capabilitySetType = CB_CAPSTYPE_GENERAL;
    gen.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    gen.version = CB_CAPS_VERSION_2;
    gen.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&gen;
    return c->ClientCapabilities(c, &caps);
}

// 向服务器广播本地剪贴板格式：有缓存文本则通告 CF_UNICODETEXT，否则空列表（表示本地无可共享内容）。
static UINT termo_cliprdr_send_format_list(TermoRDPHandle *h) {
    CliprdrClientContext *c = h ? h->cliprdr : NULL;
    if (!c) return CHANNEL_RC_OK;
    CLIPRDR_FORMAT fmt = { 0 };
    fmt.formatId = CF_UNICODETEXT;
    fmt.formatName = NULL;
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = h->clip_local ? 1 : 0;
    list.formats = h->clip_local ? &fmt : NULL;
    return c->ClientFormatList(c, &list);
}

// 服务器就绪 → 回送能力 + 当前本地格式列表。
static UINT termo_cliprdr_monitor_ready(CliprdrClientContext *c, const CLIPRDR_MONITOR_READY *m) {
    (void)m;
    TermoRDPHandle *h = c ? (TermoRDPHandle *)c->custom : NULL;
    termo_cliprdr_send_caps(c);
    termo_cliprdr_send_format_list(h);
    return CHANNEL_RC_OK;
}

// 服务器剪贴板变化：回 OK，并在其提供文本时索要 UTF-16 文本数据。
static UINT termo_cliprdr_server_format_list(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST *list) {
    CLIPRDR_FORMAT_LIST_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FORMAT_LIST_RESPONSE;
    resp.common.msgFlags = CB_RESPONSE_OK;
    c->ClientFormatListResponse(c, &resp);
    int has_text = 0;
    for (UINT32 i = 0; list && i < list->numFormats; i++)
        if (list->formats[i].formatId == CF_UNICODETEXT) { has_text = 1; break; }
    if (has_text) {
        CLIPRDR_FORMAT_DATA_REQUEST req = { 0 };
        req.common.msgType = CB_FORMAT_DATA_REQUEST;
        req.requestedFormatId = CF_UNICODETEXT;
        c->ClientFormatDataRequest(c, &req);
    }
    return CHANNEL_RC_OK;
}

static UINT termo_cliprdr_server_format_list_response(CliprdrClientContext *c,
                                                      const CLIPRDR_FORMAT_LIST_RESPONSE *r) {
    (void)c; (void)r; return CHANNEL_RC_OK;
}

// 服务器索要本地剪贴板数据：用缓存的 UTF-16 文本应答（无则 FAIL）。
static UINT termo_cliprdr_server_format_data_request(CliprdrClientContext *c,
                                                     const CLIPRDR_FORMAT_DATA_REQUEST *req) {
    TermoRDPHandle *h = c ? (TermoRDPHandle *)c->custom : NULL;
    CLIPRDR_FORMAT_DATA_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
    if (h && h->clip_local && req && req->requestedFormatId == CF_UNICODETEXT) {
        resp.common.msgFlags = CB_RESPONSE_OK;
        resp.common.dataLen = h->clip_local_bytes;
        resp.requestedFormatData = (const BYTE *)h->clip_local;
    } else {
        resp.common.msgFlags = CB_RESPONSE_FAIL;
    }
    return c->ClientFormatDataResponse(c, &resp);
}

// 服务器送回我们请求的数据：UTF-16 → UTF-8 → 回调上层写入本地剪贴板。
static UINT termo_cliprdr_server_format_data_response(CliprdrClientContext *c,
                                                      const CLIPRDR_FORMAT_DATA_RESPONSE *resp) {
    TermoRDPHandle *h = c ? (TermoRDPHandle *)c->custom : NULL;
    if (!h || !resp || !(resp->common.msgFlags & CB_RESPONSE_OK)) return CHANNEL_RC_OK;
    const WCHAR *w = (const WCHAR *)resp->requestedFormatData;
    size_t wlen = resp->common.dataLen / sizeof(WCHAR);
    if (!w || wlen == 0) return CHANNEL_RC_OK;
    char *utf8 = ConvertWCharNToUtf8Alloc(w, wlen, NULL);   // 遇首个 null 截断
    if (utf8) {
        if (h->cb.on_clipboard) h->cb.on_clipboard(h->cb.userdata, utf8);
        free(utf8);
    }
    return CHANNEL_RC_OK;
}

// 通道连上 → 按名捕获上下文：disp（动态分辨率）/ cliprdr（剪贴板）。
static void termo_on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    if (!e || !e->name) return;
    TermoRDPHandle *h = ((TermoContext *)context)->owner;
    if (!h) return;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        DispClientContext *disp = (DispClientContext *)e->pInterface;
        if (!disp) return;
        disp->custom = h;
        disp->DisplayControlCaps = termo_disp_caps;
        h->disp = disp;
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *c = (CliprdrClientContext *)e->pInterface;
        if (!c) return;
        c->custom = h;
        c->MonitorReady = termo_cliprdr_monitor_ready;
        c->ServerFormatList = termo_cliprdr_server_format_list;
        c->ServerFormatListResponse = termo_cliprdr_server_format_list_response;
        c->ServerFormatDataRequest = termo_cliprdr_server_format_data_request;
        c->ServerFormatDataResponse = termo_cliprdr_server_format_data_response;
        h->cliprdr = c;
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        // 图形管线（全彩）协商成功 → 把它接入 gdi：此后帧由 gfx 表面命令（Progressive/RFX）渲染进
        // primary_buffer（32 位 BGRX），EndPaint 帧回调照常。失败/不支持时本分支不触发，留 legacy GDI（RGB16）。
        RdpgfxClientContext *gfx = (RdpgfxClientContext *)e->pInterface;
        rdpGdi *gdi = h->context ? h->context->gdi : NULL;
        if (gfx && gdi && gdi_graphics_pipeline_init(gdi, gfx)) {
            h->gfx = gfx;
            termo_log(h, 0, "图形管线已启用（全彩）");
        }
    }
}

// 通道断开 → 解绑 gfx 管线（必须在此处用事件携带的 gfx 上下文 uninit；放到 post_disconnect 会 double-free）。
static void termo_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    if (!e || !e->name) return;
    TermoRDPHandle *h = ((TermoContext *)context)->owner;
    if (!h) return;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        rdpGdi *gdi = h->context ? h->context->gdi : NULL;
        if (gdi && e->pInterface)
            gdi_graphics_pipeline_uninit(gdi, (RdpgfxClientContext *)e->pInterface);
        h->gfx = NULL;
    }
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

    // cliprdr（剪贴板同步）：同为静态 VC 入口，连上后经 ChannelConnected 捕获 CliprdrClientContext。
    PVIRTUALCHANNELENTRY clip = freerdp_channels_load_static_addin_entry(
        "cliprdr", NULL, NULL,
        FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX);
    if (clip) freerdp_channels_client_load_ex(context->channels, s, (PVIRTUALCHANNELENTRYEX)clip, NULL);
    return TRUE;
}

// ── 连接生命周期回调 ────────────────────────────────────────────────────────
static BOOL termo_pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    rdpSettings *s = context->settings;
    termo_log(termo_owner(instance), 0, "初始化连接参数…");
    if (!freerdp_settings_set_bool(s, FreeRDP_CertificateCallbackPreferPEM, TRUE)) return FALSE;
    PubSub_SubscribeChannelConnected(context->pubSub, termo_on_channel_connected);
    PubSub_SubscribeChannelDisconnected(context->pubSub, termo_on_channel_disconnected);
    return TRUE;
}

static BOOL termo_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;  // BGRX32：32bpp 无 alpha，对齐官方 Mac 客户端
    rdpContext *context = instance->context;
    context->update->BeginPaint = termo_begin_paint;
    context->update->EndPaint = termo_end_paint;
    context->update->DesktopResize = termo_desktop_resize;
    TermoRDPHandle *h = ((TermoContext *)context)->owner;
    termo_log(h, 0, "图形子系统已就绪，连接成功");
    termo_emit_state(h, TermoRDPStateConnected, NULL);
    return TRUE;
}

static void termo_post_disconnect(freerdp *instance) {
    if (!instance || !instance->context) return;
    TermoRDPHandle *h = ((TermoContext *)instance->context)->owner;
    // 注意：gfx 管线在 ChannelDisconnected 处理器里 uninit（此刻通道/gfx 上下文仍有效）；
    // 不能放这里——到 post_disconnect 时 rdpgfx 通道已被释放，再 uninit 会 double-free（rfx_context_free 野指针崩溃）。
    gdi_free(instance);
    termo_log(h, 0, "连接已断开");
    termo_emit_state(h, TermoRDPStateDisconnected, NULL);
}

// 证书校验：把决定权交给上层（弹窗询问用户 + 自管信任库）。上层回调允许阻塞——本回调在
// 后台事件循环线程，主线程弹 UI、用户点完才返回。无回调时回退「仅本次接受」（返回 2）。
// 统一不写 FreeRDP known_hosts：永久信任由上层 RDPCertTrustStore 持久化，FreeRDP 每次都问、
// 上层据库静默放行或弹窗，信任来源单一可控（亦不会日后触发 changed 拒绝路径）。
static DWORD termo_verify_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                         const char *common_name, const char *subject,
                                         const char *issuer, const char *fingerprint, DWORD flags) {
    (void)flags;
    TermoRDPHandle *h = ((TermoContext *)instance->context)->owner;
    termo_log(h, 0, "正在验证服务器证书…");
    if (h && h->cb.verify_certificate)
        return (DWORD)h->cb.verify_certificate(h->cb.userdata, host, (int)port, common_name,
                                               subject, issuer, fingerprint, 0, NULL, NULL, NULL);
    return 2;
}

// 已存指纹与本次不一致时走此回调（自签名服务器重装/证书轮换/NAT 端口复用都会触发）。
// 因本工程不写 FreeRDP known_hosts，FreeRDP 自身的 changed 路径通常不会触发（指纹比对在上层做）；
// 仍注册并把 old_* 透传上层做防御兜底，让「证书已更改」也能弹更强警告。
static DWORD termo_verify_changed_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                                 const char *common_name, const char *subject,
                                                 const char *issuer, const char *fingerprint,
                                                 const char *old_subject, const char *old_issuer,
                                                 const char *old_fingerprint, DWORD flags) {
    (void)flags;
    TermoRDPHandle *h = ((TermoContext *)instance->context)->owner;
    if (h && h->cb.verify_certificate)
        return (DWORD)h->cb.verify_certificate(h->cb.userdata, host, (int)port, common_name,
                                               subject, issuer, fingerprint, 1,
                                               old_subject, old_issuer, old_fingerprint);
    return 2;
}

// ── 事件循环线程（参照 tf_freerdp.c 的 tf_client_thread_proc）────────────────
static void *termo_thread_proc(void *arg) {
    TermoRDPHandle *h = (TermoRDPHandle *)arg;
    freerdp *instance = h->instance;

    termo_log(h, 0, "正在协商安全层并建立连接…");
    if (!freerdp_connect(instance)) {
        termo_log(h, 2, "连接失败（认证失败或服务器不可达）");
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

    termo_ensure_openssl_legacy();   // 在 NLA/NTLM 用到 MD4 之前，确保 legacy provider 已加载

    freerdp *instance = freerdp_new();
    if (!instance) return 2;
    instance->ContextSize = sizeof(TermoContext);
    instance->PreConnect = termo_pre_connect;
    instance->LoadChannels = termo_load_channels;   // 核心 reload 后回填通道（drdynvc→disp）的唯一时机
    instance->PostConnect = termo_post_connect;
    instance->PostDisconnect = termo_post_disconnect;
    instance->VerifyCertificateEx = termo_verify_certificate_ex;
    instance->VerifyChangedCertificateEx = termo_verify_changed_certificate_ex;

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
    // 注意：不要关 NetworkAutoDetect。有些服务器（如雨云测试机）会主动发 RTT 测量请求，
    // 关掉支持后 FreeRDP 收到该包会 STATE_RUN_FAILED 直接断连。那条 messageChannelId 错配只是良性告警，保留默认开。

    // 图形管线（RDPGFX）→ 全彩 32 位。用免版税编解码 Progressive/RemoteFX（构建已关 H264/FFmpeg）。
    // gfx 经 drdynvc 协商：服务器不支持（如 XP）则通道不开，自动回落 legacy GDI（不破坏现有连接）。
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, FALSE);       // 无 H264 解码，明确不通告 AVC，迫使服务器用 Progressive/RFX
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, FALSE);

    // 把 disp / rdpgfx 加入动态通道列表，drdynvc 协商后据此拉起 DisplayControl / 图形管线子通道。
    const char *disp_args[] = { "disp" };
    freerdp_client_add_dynamic_channel(s, 1, disp_args);
    const char *gfx_args[] = { "rdpgfx" };
    freerdp_client_add_dynamic_channel(s, 1, gfx_args);

    char line[192];
    snprintf(line, sizeof(line), "开始连接 %s@%s:%d", (username && *username) ? username : "(无)", host, port);
    termo_log(h, 0, line);
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

// ── 键盘输入（从主线程发；映射参照官方 client/Mac）──────────────────────────
// 发送一个 RDP 扫描码（含 KBDEXT 扩展位）的按下/抬起。
static void termo_send_scancode(rdpInput *in, UINT32 rdp_scancode, int down) {
    UINT16 flags = (rdp_scancode & KBDEXT) ? KBD_FLAGS_EXTENDED : 0;
    flags |= down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    freerdp_input_send_keyboard_event(in, flags, (UINT8)(rdp_scancode & 0xFF));
}

void termo_rdp_key(TermoRDPHandle *h, int mac_keycode, int down) {
    rdpInput *in = termo_input(h);
    if (!in) return;
    // Apple 虚拟键码 → Windows VK → RDP 扫描码（键盘类型 4 = IBM 增强 101/102 键）。
    DWORD vk = GetVirtualKeyCodeFromKeycode((DWORD)mac_keycode, WINPR_KEYCODE_TYPE_APPLE);
    DWORD sc = GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
    if ((sc & 0xFF) == 0) return;   // 无映射
    termo_send_scancode(in, sc, down);
}

void termo_rdp_modifiers(TermoRDPHandle *h, int mask) {
    rdpInput *in = termo_input(h);
    if (!in) return;
    static const struct { int bit; UINT32 sc; int toggle; } mods[] = {
        { TermoRDPModShift,    RDP_SCANCODE_LSHIFT,   0 },
        { TermoRDPModControl,  RDP_SCANCODE_LCONTROL, 0 },
        { TermoRDPModAlt,      RDP_SCANCODE_LMENU,    0 },
        { TermoRDPModCommand,  RDP_SCANCODE_LWIN,     0 },
        { TermoRDPModCapsLock, RDP_SCANCODE_CAPSLOCK, 1 },   // 锁定键：状态变化即敲一下
    };
    int changed = mask ^ h->mod_state;
    for (size_t i = 0; i < sizeof(mods) / sizeof(mods[0]); i++) {
        if (!(changed & mods[i].bit)) continue;
        if (mods[i].toggle) {
            termo_send_scancode(in, mods[i].sc, 1);
            termo_send_scancode(in, mods[i].sc, 0);
        } else {
            termo_send_scancode(in, mods[i].sc, (mask & mods[i].bit) ? 1 : 0);
        }
    }
    h->mod_state = mask;
}

void termo_rdp_resize(TermoRDPHandle *h, int width, int height) {
    if (!h || width < 1 || height < 1) return;
    // 始终记下目标尺寸。通道/能力就绪即发；否则缓存，待 DisplayControlCaps 到达由 termo_disp_caps 补发。
    h->want_w = (UINT32)width;
    h->want_h = (UINT32)height;
    if (h->dynresize_ready && h->disp)
        termo_disp_send_layout(h, (UINT32)width, (UINT32)height);
}

void termo_rdp_clipboard_offer_text(TermoRDPHandle *h, const char *utf8) {
    if (!h) return;
    free(h->clip_local);
    h->clip_local = NULL;
    h->clip_local_bytes = 0;
    if (utf8 && *utf8) {
        size_t wlen = 0;   // wcslen（不含结尾 null）
        WCHAR *w = ConvertUtf8ToWCharAlloc(utf8, &wlen);
        if (w) {
            h->clip_local = w;
            h->clip_local_bytes = (UINT32)((wlen + 1) * sizeof(WCHAR));   // CF_UNICODETEXT 含结尾 null
        }
    }
    termo_cliprdr_send_format_list(h);   // 通道未就绪时为 no-op，MonitorReady 时会再发一次
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
    free(h->clip_local);
    free(h);
}
