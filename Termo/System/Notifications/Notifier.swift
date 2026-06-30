import Foundation
import UserNotifications

/// 系统通知（上传/下载完成等）用 UserNotifications 框架
///
/// 仅在以 `.app` 形式运行时启用：纯可执行（Xcode 直接运行裸二进制）下 `UNUserNotificationCenter`
/// 拿不到 bundle 代理会崩溃，故先判断是否在 .app 包内，不在则整体降级为空操作。
enum Notifier {
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// 启动时申请通知权限（首次会弹系统授权框），并设置代理使前台也能展示通知。
    static func requestAuthIfNeeded() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = ForegroundPresenter.shared   // 否则 App 在前台时通知会被系统静默吞掉
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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

/// 让 App 处于前台时通知也能展示为横幅 + 声音（默认前台会被系统抑制，导致「看着传完却没通知」）。
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundPresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
