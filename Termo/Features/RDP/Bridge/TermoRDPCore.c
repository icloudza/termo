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
#include <pthread.h>

#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/version.h>
#include <freerdp/settings.h>
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
};

static void termo_emit_state(TermoRDPHandle *h, TermoRDPState s, const char *msg) {
    if (h && h->cb.on_state) h->cb.on_state(h->cb.userdata, s, msg);
}

// ── 绘制回调 ────────────────────────────────────────────────────────────────
static BOOL termo_begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd &&
        gdi->primary->hdc->hwnd->invalid)
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL termo_end_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary_buffer) return TRUE;
    TermoRDPHandle *h = ((TermoContext *)context)->owner;
    if (h && h->cb.on_frame)
        h->cb.on_frame(h->cb.userdata, gdi->primary_buffer, gdi->width, gdi->height, (int)gdi->stride);
    return TRUE;
}

static BOOL termo_desktop_resize(rdpContext *context) {
    rdpSettings *s = context->settings;
    return gdi_resize(context->gdi, freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
                      freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight));
}

// ── 连接生命周期回调 ────────────────────────────────────────────────────────
static BOOL termo_pre_connect(freerdp *instance) {
    rdpSettings *s = instance->context->settings;
    if (!freerdp_settings_set_bool(s, FreeRDP_CertificateCallbackPreferPEM, TRUE)) return FALSE;
    return TRUE;
}

static BOOL termo_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;  // BGRA32：直接喂 macOS 位图/CGImage
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
