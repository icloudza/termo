//  FreeRDP C 调用层（编译为纯 C，不含 Foundation/CoreFoundation/IOKit）。
//  把 FreeRDP/WinPR 的类型与调用全部关在本 TU 内，对外只暴露 C 基本类型（见 TermoRDPCore.h），
//  从根上避开 WinPR 的 GUID/IID/REFIID 与 CoreFoundation CFPlugInCOM/IOKit 同名 COM 类型的冲突。
#include "TermoRDPCore.h"

#include <stdio.h>
#include <freerdp/freerdp.h>
#include <freerdp/version.h>

const char *termo_rdp_freerdp_version(void) {
    static char buf[32];
    snprintf(buf, sizeof(buf), "%d.%d.%d",
             FREERDP_VERSION_MAJOR, FREERDP_VERSION_MINOR, FREERDP_VERSION_REVISION);
    return buf;
}

int termo_rdp_link_probe(void) {
    freerdp *inst = freerdp_new();
    if (!inst) return 0;
    freerdp_free(inst);
    return 1;
}
