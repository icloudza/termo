import Foundation

extension Bundle {
    /// 打包资源所在的 bundle：SwiftPM 构建为 `.module`，Xcode App target 构建为 `.main`。
    /// 用 `SWIFT_PACKAGE` 宏区分（仅 SwiftPM 构建会定义该宏），使同一份代码在两种工程形态下
    /// 都能取到随包资源（AppIcon、font-logos、Nerd Font 等）。迁入 App target 后资源进 `.main`，
    /// 此时不存在 `Bundle.module`，故统一经此访问器取用。
    static var app: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
}
