import Foundation

/// 运行渠道判定（Developer ID 直发 vs Mac App Store 沙盒）。
/// 用于按渠道隐藏本地终端、调整私钥导入方式等。详见 [[ssh-libssh2-migration]] 的两构建一套代码方案。
enum AppEnv {
    /// 编译期：MAS（App Sandbox）构建。由 ReleaseMAS 配置的 `SWIFT_ACTIVE_COMPILATION_CONDITIONS=TERMO_MAS` 决定。
    static var isMAS: Bool {
        #if TERMO_MAS
        return true
        #else
        return false
        #endif
    }

    /// 是否运行在 App Sandbox 中（运行期判定，兜底）。MAS 构建恒为真；非沙盒 Dev ID 为假。
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// 是否经 Mac App Store 安装（有 App Store 收据）。供「检查更新」等按渠道分流（当前无自更新功能，预留）。
    static var isAppStoreReceiptPresent: Bool {
        guard let url = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 本地终端是否可用：MAS 沙盒下隐藏（沙盒内 spawn 的 shell 被关在容器、无实际用途）。
    static var localTerminalEnabled: Bool { !isMAS }
}
