#import "TermoRDPSession.h"
#import "TermoRDPCore.h"   // 纯 C 层；本文件不 include 任何 FreeRDP 头，避免类型宇宙冲突

static void termo_bridge_on_state(void *userdata, TermoRDPState state, const char *message);
static void termo_bridge_on_frame(void *userdata, const uint8_t *bgra, int width, int height, int stride);

@implementation TermoRDPSession {
    NSString *_host;
    int _port;
    NSString *_username;
    NSString *_password;
    NSString *_domain;
    int _width;
    int _height;
    TermoRDPHandle *_handle;
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
    }
    return self;
}

- (void)connect {
    if (_handle) return;
    TermoRDPCallbacks cb = { 0 };
    cb.userdata = (__bridge void *)self;   // 非持有：本对象在 dealloc 里 termo_rdp_free（join 线程）后才销毁
    cb.on_state = termo_bridge_on_state;
    cb.on_frame = termo_bridge_on_frame;
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
    if (_handle) termo_rdp_disconnect(_handle);
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

- (void)dealloc {
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

static void termo_bridge_on_frame(void *userdata, const uint8_t *bgra, int width, int height, int stride) {
    TermoRDPSession *session = (__bridge TermoRDPSession *)userdata;
    // 拷贝整帧（FreeRDP 缓冲回调返回后即可能变化），跨线程交给主线程渲染。
    NSData *data = [NSData dataWithBytes:bgra length:(NSUInteger)height * (NSUInteger)stride];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([session.delegate respondsToSelector:@selector(rdpSession:didReceiveFrame:width:height:stride:)])
            [session.delegate rdpSession:session didReceiveFrame:data width:width height:height stride:stride];
    });
}
