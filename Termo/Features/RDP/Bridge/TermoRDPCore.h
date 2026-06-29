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

/// 动态分辨率：请求远端桌面改为 width×height（经 DisplayControl 通道；通道未就绪则忽略）。
void termo_rdp_resize(TermoRDPHandle *handle, int width, int height);

/// 请求断开（令事件循环退出，线程自然结束）。
void termo_rdp_disconnect(TermoRDPHandle *handle);

/// 断开并释放（会 join 后台线程）。
void termo_rdp_free(TermoRDPHandle *handle);

#ifdef __cplusplus
}
#endif

#endif /* TERMO_RDP_CORE_H */
