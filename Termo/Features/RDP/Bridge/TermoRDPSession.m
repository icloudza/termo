#import "TermoRDPSession.h"
#import "TermoRDPCore.h"   // 纯 C 层；本文件不 include 任何 FreeRDP 头，避免类型宇宙冲突

static void termo_bridge_on_state(void *userdata, TermoRDPState state, const char *message);
static void termo_bridge_on_frame(void *userdata, const uint8_t *pixels, int width, int height, int stride, int bpp);
static void termo_bridge_on_log(void *userdata, int level, const char *text);
static int termo_bridge_verify_certificate(void *userdata, const char *host, int port,
                                           const char *common_name, const char *subject,
                                           const char *issuer, const char *fingerprint, int changed,
                                           const char *old_subject, const char *old_issuer,
                                           const char *old_fingerprint);

@implementation TermoRDPSession {
    NSString *_host;
    int _port;
    NSString *_username;
    NSString *_password;
    NSString *_domain;
    int _width;
    int _height;
    TermoRDPHandle *_handle;
    // 证书校验跨线程同步：后台线程发起后阻塞在 _certSem 上，主线程经 delegate 决定后 resolve 唤醒。
    NSLock *_certLock;
    dispatch_semaphore_t _certSem;   // 非 nil 表示有一次证书决定正在等待
    NSInteger _certDecision;
}

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    username:(NSString *)username
                    password:(NSString *)password
                      domain:(NSString *)domain
                       width:(int)width
                      height:(int)height {
    if ((self = [super init])) {
        _host = [host copy];
        _port = port;
        _username = [username copy];
        _password = [password copy];
        _domain = [domain copy];
        _width = width;
        _height = height;
        _certLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)connect {
    if (_handle) return;
    TermoRDPCallbacks cb = { 0 };
    cb.userdata = (__bridge void *)self;   // 非持有：本对象在 dealloc 里 termo_rdp_free（join 线程）后才销毁
    cb.on_state = termo_bridge_on_state;
    cb.on_frame = termo_bridge_on_frame;
    cb.on_log = termo_bridge_on_log;
    cb.verify_certificate = termo_bridge_verify_certificate;
    _handle = termo_rdp_create(cb);
    int rc = termo_rdp_connect(_handle, _host.UTF8String, _port,
                               _username.UTF8String, _password.UTF8String,
                               _domain.UTF8String, _width, _height);
    if (rc != 0 && [self.delegate respondsToSelector:@selector(rdpSession:didChangeState:message:)]) {
        [self.delegate rdpSession:self
                   didChangeState:TermoRDPStateFailed
                          message:[NSString stringWithFormat:@"连接启动失败 (%d)", rc]];
    }
}

- (void)disconnect {
    [self resolveCertificate:0];   // 若正卡在证书弹窗，按「拒绝」放行后台线程，使其能干净退出
    if (_handle) termo_rdp_disconnect(_handle);
}

// MARK: - 证书校验跨线程同步

// 后台事件循环线程调用：发起主线程弹窗并阻塞等待用户决定（0/1/2）。
- (NSInteger)waitForCertificateDecisionHost:(NSString *)host port:(int)port
                                 commonName:(NSString *)commonName subject:(NSString *)subject
                                     issuer:(NSString *)issuer fingerprint:(NSString *)fingerprint
                                    changed:(BOOL)changed oldSubject:(NSString *)oldSubject
                                  oldIssuer:(NSString *)oldIssuer oldFingerprint:(NSString *)oldFingerprint {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [_certLock lock];
    _certSem = sem;
    _certDecision = 0;   // 默认拒绝：断开/释放时若未及决定，按拒绝兜底
    [_certLock unlock];

    __weak TermoRDPSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        TermoRDPSession *s = weakSelf;
        if (!s) return;   // 对象已释放：dealloc 已先行 resolve，等待方不会卡住
        id<TermoRDPSessionDelegate> d = s.delegate;
        SEL sel = @selector(rdpSession:verifyCertificateForHost:port:commonName:subject:issuer:fingerprint:changed:oldSubject:oldIssuer:oldFingerprint:completion:);
        if (![d respondsToSelector:sel]) {
            [s resolveCertificate:2];   // 未实现：默认仅本次接受（保持旧行为，不阻断连接）
            return;
        }
        [d rdpSession:s verifyCertificateForHost:host port:port commonName:commonName
              subject:subject issuer:issuer fingerprint:fingerprint changed:changed
           oldSubject:oldSubject oldIssuer:oldIssuer oldFingerprint:oldFingerprint
           completion:^(NSInteger decision) { [s resolveCertificate:decision]; }];
    });

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    [_certLock lock];
    NSInteger decision = _certDecision;
    [_certLock unlock];
    return decision;
}

// 回填证书决定并唤醒等待的后台线程；以 _certSem 置 nil 作为「已解决」标记，杜绝二次 signal。
- (void)resolveCertificate:(NSInteger)decision {
    [_certLock lock];
    dispatch_semaphore_t sem = _certSem;
    if (sem) {
        _certDecision = decision;
        _certSem = nil;
        dispatch_semaphore_signal(sem);
    }
    [_certLock unlock];
}

- (void)sendMouseMoveX:(int)x y:(int)y {
    if (_handle) termo_rdp_mouse_move(_handle, x, y);
}
- (void)sendMouseButton:(int)button down:(BOOL)down x:(int)x y:(int)y {
    if (_handle) termo_rdp_mouse_button(_handle, button, down ? 1 : 0, x, y);
}
- (void)sendMouseWheel:(int)delta x:(int)x y:(int)y {
    if (_handle) termo_rdp_mouse_wheel(_handle, delta, x, y);
}
- (void)resizeToWidth:(int)width height:(int)height {
    if (_handle) termo_rdp_resize(_handle, width, height);
}

- (void)dealloc {
    [self resolveCertificate:0];   // 先解锁可能卡在证书等待的后台线程，否则下面 join 会死锁
    if (_handle) {
        termo_rdp_free(_handle);   // 会 join 后台线程，确保此后不再有回调
        _handle = NULL;
    }
}

+ (NSString *)freerdpVersion {
    return [NSString stringWithUTF8String:termo_rdp_freerdp_version()];
}

@end

// ── C 回调蹦床：转回 ObjC delegate（已在主线程）────────────────────────────
static void termo_bridge_on_state(void *userdata, TermoRDPState state, const char *message) {
    TermoRDPSession *session = (__bridge TermoRDPSession *)userdata;
    NSString *msg = message ? [NSString stringWithUTF8String:message] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([session.delegate respondsToSelector:@selector(rdpSession:didChangeState:message:)])
            [session.delegate rdpSession:session didChangeState:(NSInteger)state message:msg];
    });
}

static void termo_bridge_on_frame(void *userdata, const uint8_t *pixels, int width, int height, int stride, int bpp) {
    TermoRDPSession *session = (__bridge TermoRDPSession *)userdata;
    // 拷贝整帧（FreeRDP 缓冲回调返回后即可能变化），跨线程交给主线程渲染。
    NSData *data = [NSData dataWithBytes:pixels length:(NSUInteger)height * (NSUInteger)stride];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([session.delegate respondsToSelector:@selector(rdpSession:didReceiveFrame:width:height:stride:bpp:)])
            [session.delegate rdpSession:session didReceiveFrame:data width:width height:height stride:stride bpp:bpp];
    });
}

// 连接日志蹦床：转回主线程交给 delegate。
static void termo_bridge_on_log(void *userdata, int level, const char *text) {
    if (!text) return;
    TermoRDPSession *session = (__bridge TermoRDPSession *)userdata;
    NSString *line = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([session.delegate respondsToSelector:@selector(rdpSession:didLog:level:)])
            [session.delegate rdpSession:session didLog:line level:(NSInteger)level];
    });
}

// 证书校验蹦床（后台线程，同步阻塞直到用户决定）。C 字符串转 NSString 后转交 ObjC 阻塞等待。
static int termo_bridge_verify_certificate(void *userdata, const char *host, int port,
                                           const char *common_name, const char *subject,
                                           const char *issuer, const char *fingerprint, int changed,
                                           const char *old_subject, const char *old_issuer,
                                           const char *old_fingerprint) {
    TermoRDPSession *session = (__bridge TermoRDPSession *)userdata;
#define TS(x) ((x) ? [NSString stringWithUTF8String:(x)] : nil)
    NSInteger decision = [session waitForCertificateDecisionHost:(TS(host) ?: @"")
                                                            port:port
                                                      commonName:TS(common_name)
                                                         subject:TS(subject)
                                                          issuer:TS(issuer)
                                                     fingerprint:TS(fingerprint)
                                                         changed:(changed != 0)
                                                      oldSubject:TS(old_subject)
                                                       oldIssuer:TS(old_issuer)
                                                  oldFingerprint:TS(old_fingerprint)];
#undef TS
    return (int)decision;
}
