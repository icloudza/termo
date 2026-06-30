#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TermoRDPSession;

/// RDP 会话事件回调（均已在主线程派发）。
/// state 取值对应 TermoRDPCore 的 TermoRDPState：0=连接中 1=已连接 2=已断开 3=失败。
@protocol TermoRDPSessionDelegate <NSObject>
@optional
- (void)rdpSession:(TermoRDPSession *)session didChangeState:(NSInteger)state message:(nullable NSString *)message;
- (void)rdpSession:(TermoRDPSession *)session
    didReceiveFrame:(NSData *)pixels
              width:(int)width
             height:(int)height
             stride:(int)stride
                bpp:(int)bpp;

/// 连接日志（已派发到主线程，供连接面板「实时日志」展示）。level：0=信息 1=警告 2=错误。
- (void)rdpSession:(TermoRDPSession *)session didLog:(NSString *)text level:(NSInteger)level;

/// 远端剪贴板文本到达（已派发到主线程）：上层写入本地剪贴板。
- (void)rdpSession:(TermoRDPSession *)session didReceiveClipboardText:(NSString *)text;

/// 证书信任校验（已派发到主线程）。changed=YES 表示与已信任指纹不一致（old* 为旧证书信息）。
/// 实现方在用户决定后调用 completion 回传：0=拒绝、1=永久信任、2=仅本次。可异步调用 completion
/// （底层后台线程会阻塞等待）；不实现本方法时底层默认「仅本次接受」。
- (void)rdpSession:(TermoRDPSession *)session
    verifyCertificateForHost:(NSString *)host
                        port:(int)port
                  commonName:(nullable NSString *)commonName
                     subject:(nullable NSString *)subject
                      issuer:(nullable NSString *)issuer
                 fingerprint:(nullable NSString *)fingerprint
                     changed:(BOOL)changed
                  oldSubject:(nullable NSString *)oldSubject
                   oldIssuer:(nullable NSString *)oldIssuer
              oldFingerprint:(nullable NSString *)oldFingerprint
                  completion:(void (^)(NSInteger decision))completion;
@end

/// FreeRDP 会话的 ObjC 桥：经纯 C 层 TermoRDPCore 驱动连接/事件循环/帧回调，对 Swift 暴露 KVO/delegate 接口。
@interface TermoRDPSession : NSObject

@property (nonatomic, weak) id<TermoRDPSessionDelegate> delegate;

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    username:(NSString *)username
                    password:(NSString *)password
                      domain:(NSString *)domain
                       width:(int)width
                      height:(int)height;

- (void)connect;
- (void)disconnect;
/// 同步关闭：解开证书等待、abort 并 **join** 后台事件循环线程后释放（退出 App 前调用，确保无残留线程）。
- (void)shutdown;

// 鼠标输入（x/y 为远端桌面像素坐标）。
- (void)sendMouseMoveX:(int)x y:(int)y;
- (void)sendMouseButton:(int)button down:(BOOL)down x:(int)x y:(int)y;  // button 0=左 1=右 2=中
- (void)sendMouseWheel:(int)delta x:(int)x y:(int)y;

// 键盘输入。keyCode 为 macOS 虚拟键码（NSEvent.keyCode）；mask 为修饰键掩码（见 TermoRDPCore.h 的 TermoRDPModMask）。
- (void)sendKey:(int)keyCode down:(BOOL)down;
- (void)sendModifiers:(int)mask;

/// 本地剪贴板文本变化：广播给远端（经 CLIPRDR）。传 nil/空表示本地无文本可共享。
- (void)offerClipboardText:(nullable NSString *)text;

/// 动态分辨率：请求远端桌面改为 width×height。
- (void)resizeToWidth:(int)width height:(int)height;

/// 链接自检：返回内嵌 FreeRDP 版本串。
+ (NSString *)freerdpVersion;

@end

NS_ASSUME_NONNULL_END
