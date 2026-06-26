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

    // ---------- 终端 ----------
    /// 终端字体名（空 = 自动回退到预置等宽字体）。
    @Published var termFont: String {
        didSet { d.set(termFont, forKey: "termFont") }
    }
    @Published var termFontSize: Int {
        didSet { d.set(termFontSize, forKey: "termFontSize") }
    }
    /// 光标形状：block / bar / underline。
    @Published var termCursorStyle: String {
        didSet { d.set(termCursorStyle, forKey: "termCursorStyle") }
    }
    @Published var termCursorBlink: Bool {
        didSet { d.set(termCursorBlink, forKey: "termCursorBlink") }
    }
    /// 滚动缓冲区行数。
    @Published var termScrollback: Int {
        didSet { d.set(termScrollback, forKey: "termScrollback") }
    }

    private init() {
        startupBehavior = StartupBehavior(rawValue: d.string(forKey: "startupBehavior") ?? "") ?? .welcome
        defaultShell = DefaultShell(rawValue: d.string(forKey: "defaultShell") ?? "") ?? .auto
        closeConfirm = d.object(forKey: "closeConfirm") as? Bool ?? true
        editorMinimap = d.object(forKey: "editorMinimap") as? Bool ?? true
        termFont = d.string(forKey: "termFont") ?? ""
        termFontSize = d.object(forKey: "termFontSize") as? Int ?? 12
        termCursorStyle = d.string(forKey: "termCursorStyle") ?? "block"
        termCursorBlink = d.object(forKey: "termCursorBlink") as? Bool ?? true
        termScrollback = d.object(forKey: "termScrollback") as? Int ?? 10000
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
