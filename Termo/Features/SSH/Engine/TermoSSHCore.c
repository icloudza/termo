//  libssh2 引擎 C 实现。J1：链接自检。
#include "TermoSSHCore.h"
#include <libssh2.h>

const char *termo_ssh_libssh2_version(void) {
    return libssh2_version(0);
}

int termo_ssh_self_test(void) {
    int rc = libssh2_init(0);   // 0 = 不禁用任何加密；触发 OpenSSL 初始化（验证符号解析）
    if (rc == 0) libssh2_exit();
    return rc;
}
