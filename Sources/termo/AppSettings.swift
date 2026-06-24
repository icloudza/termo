import Foundation

enum StartupBehavior: String, CaseIterable, Hashable {
    case welcome, terminal, restore
}

enum DefaultShell: String, CaseIterable, Hashable {
    case auto, zsh, bash
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
    /// 代码编辑器右侧缩略图（minimap）。
    @Published var editorMinimap: Bool {
        didSet { d.set(editorMinimap, forKey: "editorMinimap") }
    }

    private init() {
        startupBehavior = StartupBehavior(rawValue: d.string(forKey: "startupBehavior") ?? "") ?? .welcome
        defaultShell = DefaultShell(rawValue: d.string(forKey: "defaultShell") ?? "") ?? .auto
        closeConfirm = d.object(forKey: "closeConfirm") as? Bool ?? true
        editorMinimap = d.object(forKey: "editorMinimap") as? Bool ?? true
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
