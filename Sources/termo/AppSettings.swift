import Foundation

enum StartupBehavior: String, CaseIterable, Hashable {
    case welcome, terminal, restore
}

enum DefaultShell: String, CaseIterable, Hashable {
    case auto, zsh, bash
}

enum WindowEffect: String, CaseIterable, Hashable {
    case none = "无"
    case blur = "高斯模糊"
    case mica = "云母"
}

/// 全局应用设置，UserDefaults 持久化。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var startupBehavior: StartupBehavior {
        didSet { d.set(startupBehavior.rawValue, forKey: "startupBehavior") }
    }
    @Published var defaultShell: DefaultShell {
        didSet { d.set(defaultShell.rawValue, forKey: "defaultShell") }
    }
    @Published var closeConfirm: Bool {
        didSet { d.set(closeConfirm, forKey: "closeConfirm") }
    }
    @Published var windowOpacity: Double {
        didSet { d.set(windowOpacity, forKey: "windowOpacity") }
    }
    @Published var windowEffect: WindowEffect {
        didSet { d.set(windowEffect.rawValue, forKey: "windowEffect") }
    }

    private init() {
        startupBehavior = StartupBehavior(rawValue: d.string(forKey: "startupBehavior") ?? "") ?? .welcome
        defaultShell = DefaultShell(rawValue: d.string(forKey: "defaultShell") ?? "") ?? .auto
        closeConfirm = d.object(forKey: "closeConfirm") as? Bool ?? true
        windowOpacity = d.object(forKey: "windowOpacity") as? Double ?? 1.0
        windowEffect = WindowEffect(rawValue: d.string(forKey: "windowEffect") ?? "") ?? .none
    }

    /// 是否需要让窗口透明（开了模糊效果或透明度 < 1）。
    var needsTransparentWindow: Bool {
        windowEffect != .none || windowOpacity < 0.999
    }

    /// 窗口表面（侧栏/活动栏/工作区/终端）的不透明度。
    var surfaceAlpha: Double {
        needsTransparentWindow ? windowOpacity : 1.0
    }

    /// 解析出实际的 shell 可执行路径。
    var resolvedShell: String {
        switch defaultShell {
        case .auto: return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        case .zsh: return "/bin/zsh"
        case .bash: return "/bin/bash"
        }
    }
}
