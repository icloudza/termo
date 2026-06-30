//  进程内 SSH 引擎的 C 接口（基于 libssh2）。SSH 迁移 J1：先只做链接自检，后续扩展为
//  连接/认证/exec/SFTP/PTY/端口转发的完整引擎，替换现有 spawn /usr/bin/ssh 的实现。
//
//  注：libssh2 是纯 SSH C 库，与 Foundation/CoreFoundation 无类型冲突（不像 FreeRDP/WinPR），
//  故可直接 #include <libssh2.h>，无需 FreeRDP 那种纯 C 隔离 TU。
#ifndef TERMO_SSH_CORE_H
#define TERMO_SSH_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 返回内嵌 libssh2 版本串（如 "1.11.1"）；指向静态缓冲，勿 free。
const char *termo_ssh_libssh2_version(void);

/// 链接 + 运行自检：libssh2_init/exit 往返。返回 0 成功。
/// 作用＝强制链接 libssh2（连带其对 OpenSSL 的引用），验证那些符号能从 CFreeRDP 的 OpenSSL 解析。
int termo_ssh_self_test(void);

#ifdef __cplusplus
}
#endif

#endif /* TERMO_SSH_CORE_H */
