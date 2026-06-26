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

    /// 默认下载目录（空=系统下载文件夹）。
    @Published var downloadDir: String {
        didSet { d.set(downloadDir, forKey: "downloadDir") }
    }
    /// 每次下载都询问保存位置。
    @Published var downloadAskEachTime: Bool {
        didSet { d.set(downloadAskEachTime, forKey: "downloadAskEachTime") }
    }

    /// 资源告警：监控到 CPU/内存/磁盘持续高占用时发系统通知。
    @Published var resourceAlerts: Bool {
        didSet { d.set(resourceAlerts, forKey: "resourceAlerts") }
    }

    /// 监控安全说明是否已确认（点「我已知晓」后永久关闭该提示）。
    @Published var monitorNoticeAck: Bool {
        didSet { d.set(monitorNoticeAck, forKey: "monitorNoticeAck") }
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
        downloadDir = d.string(forKey: "downloadDir") ?? ""
        downloadAskEachTime = d.object(forKey: "downloadAskEachTime") as? Bool ?? false
        resourceAlerts = d.object(forKey: "resourceAlerts") as? Bool ?? true
        monitorNoticeAck = d.object(forKey: "monitorNoticeAck") as? Bool ?? false
    }

    /// 实际下载目录：设置为空则用系统下载文件夹。
    var resolvedDownloadDir: URL {
        if !downloadDir.isEmpty {
            return URL(fileURLWithPath: (downloadDir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
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
