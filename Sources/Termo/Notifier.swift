import Foundation
import UserNotifications

/// 系统通知（上传/下载完成等）。用 Apple 自带 UserNotifications 框架，无需第三方权限库。
///
/// 仅在以 `.app` 形式运行时启用：纯可执行（Xcode 直接运行裸二进制）下 `UNUserNotificationCenter`
/// 拿不到 bundle 代理会崩溃，故先判断是否在 .app 包内，不在则整体降级为空操作。
enum Notifier {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// 启动时申请通知权限（首次会弹系统授权框）。
    static func requestAuthIfNeeded() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 发一条系统通知。未授权时系统自行忽略。
    static func notify(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
