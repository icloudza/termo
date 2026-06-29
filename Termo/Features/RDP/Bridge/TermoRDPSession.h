#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// RDP 会话事件回调。阶段 C 起逐步填充：帧缓冲更新、连接态变化、证书确认等。
@protocol TermoRDPSessionDelegate <NSObject>
@optional
- (void)rdpSessionDidConnect:(id)session;
- (void)rdpSession:(id)session didFailWithMessage:(NSString *)message;
@end

/// FreeRDP 会话的 ObjC 桥：把 FreeRDP 的 C API / 回调 / 事件循环收窄成 Swift 可用的对象接口。
/// 阶段 C 起实现真正的 connect（freerdp_connect + 后台事件循环 + 帧回调）；当前为接缝 + 链接自检。
@interface TermoRDPSession : NSObject

@property (nonatomic, weak) id<TermoRDPSessionDelegate> delegate;

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    username:(NSString *)username
                    password:(NSString *)password;

- (void)connect;
- (void)disconnect;

/// 链接自检：返回内嵌 FreeRDP 的版本串，证明已正确链接到 CFreeRDP 静态库。
+ (NSString *)freerdpVersion;

@end

NS_ASSUME_NONNULL_END
