//  纯 C 接口层：隔离 FreeRDP/WinPR 的类型宇宙（GUID/IID 等）与 ObjC/Foundation
//  （CFPlugInCOM/IOKit 同名 COM 类型）。本头**只暴露 C 基本类型**，不外泄任何 FreeRDP 类型，
//  故 ObjC 桥可安全 #import 它而不会把两套冲突类型拉进同一编译单元。
//  实现见 TermoRDPCore.c（编译为 C，不含 Foundation）。
#ifndef TERMO_RDP_CORE_H
#define TERMO_RDP_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 连接状态。
typedef enum {
    TermoRDPStateConnecting = 0,
    TermoRDPStateConnected = 1,
    TermoRDPStateDisconnected = 2,
    TermoRDPStateFailed = 3,
} TermoRDPState;

/// 回调集合（注意：均从后台事件循环线程触发，调用方需自行跨线程到主线程使用）。
typedef struct {
    void *userdata;
    /// 一帧合成完成：pixels 为全帧缓冲（由 FreeRDP 拥有，回调返回后即可能变化——需自行拷贝）。
    /// bpp = 每像素字节数（2=RGB16 / 4=BGRX32）；据此选 CGImage 的位序与每分量位深（参考官方 Mac/iOS 客户端）。
    void (*on_frame)(void *userdata, const uint8_t *pixels, int width, int height, int stride, int bpp);
    /// 状态变化；message 可为 NULL。
    void (*on_state)(void *userdata, TermoRDPState state, const char *message);
    /// 连接日志（各生命周期点上报，供连接面板「实时日志」展示）。level：0=信息 1=警告 2=错误。
    void (*on_log)(void *userdata, int level, const char *text);
    /// 远端剪贴板文本到达（UTF-8）：上层据此写入本地剪贴板。从后台线程触发，需自行跨线程。
    void (*on_clipboard)(void *userdata, const char *utf8_text);
    /// 证书信任校验（从后台事件循环线程**同步**调用，允许阻塞等待用户决定）。
    /// changed=0 首见证书、1 与已存指纹不一致（old_* 提供旧证书信息，否则为 NULL）。
    /// 返回：0=拒绝连接、1=接受并永久信任、2=仅本次接受。回调为 NULL 时底层默认 2（仅本次）。
    int (*verify_certificate)(void *userdata, const char *host, int port,
                              const char *common_name, const char *subject,
                              const char *issuer, const char *fingerprint, int changed,
                              const char *old_subject, const char *old_issuer,
                              const char *old_fingerprint);
} TermoRDPCallbacks;

/// 不透明会话句柄。
typedef struct TermoRDPHandle TermoRDPHandle;

/// 返回内嵌 FreeRDP 版本串（如 "3.9.0"）；指向静态缓冲，调用方勿 free。
const char *termo_rdp_freerdp_version(void);

/// 创建会话（尚未连接）。
TermoRDPHandle *termo_rdp_create(TermoRDPCallbacks callbacks);

/// 异步连接：起后台线程跑 freerdp_connect + 事件循环；立即返回 0，参数错误返回非 0。
int termo_rdp_connect(TermoRDPHandle *handle, const char *host, int port,
                      const char *username, const char *password,
                      const char *domain, int width, int height);

/// 鼠标移动（x/y 为远端桌面像素坐标）。
void termo_rdp_mouse_move(TermoRDPHandle *handle, int x, int y);
/// 鼠标按键：button 0=左 1=右 2=中；down=1 按下、0 抬起。
void termo_rdp_mouse_button(TermoRDPHandle *handle, int button, int down, int x, int y);
/// 滚轮：delta 正=上滚、负=下滚（约 120/格）。
void termo_rdp_mouse_wheel(TermoRDPHandle *handle, int delta, int x, int y);

/// 修饰键抽象位（与 NSEvent 解耦，由上层翻译后传入；底层据此与上次状态 diff 发送增量）。
typedef enum {
    TermoRDPModShift    = 1 << 0,
    TermoRDPModControl  = 1 << 1,
    TermoRDPModAlt      = 1 << 2,   // ⌥ Option → 远端 Alt
    TermoRDPModCommand  = 1 << 3,   // ⌘ Command → 远端左 Win
    TermoRDPModCapsLock = 1 << 4,   // 锁定切换键
} TermoRDPModMask;

/// 普通按键：mac_keycode 为 macOS 虚拟键码（NSEvent.keyCode）；down=1 按下、0 抬起。
/// 底层经 WinPR 映射 Apple keycode → Windows VK → RDP 扫描码后发送（含扩展键标志）。
void termo_rdp_key(TermoRDPHandle *handle, int mac_keycode, int down);
/// 修饰键状态变化：传入当前修饰键掩码（TermoRDPModMask 或运算），底层与上次比对后发送按下/抬起增量。
void termo_rdp_modifiers(TermoRDPHandle *handle, int mod_mask);

/// 动态分辨率：请求远端桌面改为 width×height（经 DisplayControl 通道；通道未就绪则忽略）。
void termo_rdp_resize(TermoRDPHandle *handle, int width, int height);

/// 本地剪贴板文本变化（UTF-8）：向服务器广播「本地有文本」（经 CLIPRDR 通道）。传 NULL/空串表示清空。
/// 服务器随后按需取数据；通道未就绪则仅缓存，MonitorReady 后再广播。
void termo_rdp_clipboard_offer_text(TermoRDPHandle *handle, const char *utf8_text);

/// 请求断开（令事件循环退出，线程自然结束）。
void termo_rdp_disconnect(TermoRDPHandle *handle);

/// 断开并释放（会 join 后台线程）。
void termo_rdp_free(TermoRDPHandle *handle);

#ifdef __cplusplus
}
#endif

#endif /* TERMO_RDP_CORE_H */
