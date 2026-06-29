#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TermoRDPSession;

/// RDP 会话事件回调（均已在主线程派发）。
/// state 取值对应 TermoRDPCore 的 TermoRDPState：0=连接中 1=已连接 2=已断开 3=失败。
@protocol TermoRDPSessionDelegate <NSObject>
@optional
- (void)rdpSession:(TermoRDPSession *)session didChangeState:(NSInteger)state message:(nullable NSString *)message;
- (void)rdpSession:(TermoRDPSession *)session
    didReceiveFrame:(NSData *)bgra
              width:(int)width
             height:(int)height
             stride:(int)stride;
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

// 鼠标输入（x/y 为远端桌面像素坐标）。
- (void)sendMouseMoveX:(int)x y:(int)y;
- (void)sendMouseButton:(int)button down:(BOOL)down x:(int)x y:(int)y;  // button 0=左 1=右 2=中
- (void)sendMouseWheel:(int)delta x:(int)x y:(int)y;

/// 链接自检：返回内嵌 FreeRDP 版本串。
+ (NSString *)freerdpVersion;

@end

NS_ASSUME_NONNULL_END
