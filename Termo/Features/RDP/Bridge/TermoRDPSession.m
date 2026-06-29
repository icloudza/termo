#import "TermoRDPSession.h"
#import "TermoRDPCore.h"   // 纯 C 层；本文件不 include 任何 FreeRDP 头，避免类型宇宙冲突

/// 阶段 C 起：经 TermoRDPCore 的 C 接口驱动 freerdp 连接/事件循环/帧回调。
/// 当前为接缝实现：仅经 C 层做链接自检，不真正连接。
@implementation TermoRDPSession {
    NSString *_host;
    int _port;
    NSString *_username;
    NSString *_password;
}

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    username:(NSString *)username
                    password:(NSString *)password {
    if ((self = [super init])) {
        _host = [host copy];
        _port = port;
        _username = [username copy];
        _password = [password copy];
    }
    return self;
}

- (void)connect {
    // 接缝：经 C 层验证已链接到 FreeRDP。阶段 C 替换为完整连接流程。
    if (!termo_rdp_link_probe()) {
        if ([self.delegate respondsToSelector:@selector(rdpSession:didFailWithMessage:)]) {
            [self.delegate rdpSession:self didFailWithMessage:@"FreeRDP 链接自检失败"];
        }
    }
}

- (void)disconnect {
    // 阶段 C：经 C 层 freerdp_disconnect + 结束事件循环线程。
}

+ (NSString *)freerdpVersion {
    return [NSString stringWithUTF8String:termo_rdp_freerdp_version()];
}

@end
