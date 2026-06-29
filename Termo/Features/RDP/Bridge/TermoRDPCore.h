//  纯 C 接口层：隔离 FreeRDP/WinPR 的类型宇宙（GUID/IID 等）与 ObjC/Foundation
//  （CFPlugInCOM/IOKit 同名 COM 类型）。本头**只暴露 C 基本类型**，不外泄任何 FreeRDP 类型，
//  故 ObjC 桥可安全 #import 它而不会把两套冲突类型拉进同一编译单元。
//  实现见 TermoRDPCore.c（编译为 C，不含 Foundation）。
#ifndef TERMO_RDP_CORE_H
#define TERMO_RDP_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 返回内嵌 FreeRDP 版本串（如 "3.9.0"）；指向静态缓冲，调用方勿 free。
const char *termo_rdp_freerdp_version(void);

/// 链接自检：创建并释放一个 freerdp 实例，成功返回 1、失败返回 0。
/// 用于验证已正确链接到 CFreeRDP 静态库（阶段 C 起替换为真正的连接接口）。
int termo_rdp_link_probe(void);

#ifdef __cplusplus
}
#endif

#endif /* TERMO_RDP_CORE_H */
