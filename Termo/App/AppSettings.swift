import Foundation

enum StartupBehavior: String, CaseIterable, Hashable {
    case welcome, terminal
}

enum DefaultShell: String, CaseIterable, Hashable {
    case auto, zsh, bash
}

/// 代码片段点击运行时的行为：每次询问 / 仅插入命令行 / 直接运行。
enum SnippetAction: String, CaseIterable, Hashable {
    case ask, insert, run
    var label: String {
        switch self {
        case .ask: return String(localized: "每次询问")
        case .insert: return String(localized: "仅插入命令行")
        case .run: return String(localized: "直接运行")
        }
    }
}

/// RDP 远程桌面连接成功后的打开方式：每次询问 / 内嵌标签 / 新窗口（全屏）。
enum RDPOpenMode: String, CaseIterable, Hashable {
    case ask, embedded, window
    var label: String {
        switch self {
        case .ask: return String(localized: "每次询问")
        case .embedded: return String(localized: "内嵌标签")
        case .window: return String(localized: "新窗口")
        }
    }
}

/// 界面语言：跟随系统 / 简体中文 / English。默认简体中文。
enum AppLanguage: String, CaseIterable, Hashable {
    case system, zh, en
    var label: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }
    /// 写入 AppleLanguages 的语言码；system 返回 nil 表示不覆盖、跟随系统。
    var appleCode: String? {
        switch self {
        case .system: return nil
        case .zh: return "zh-Hans"
        case .en: return "en"
        }
    }
}

/// 全局应用设置，UserDefaults 持久化。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var startupBehavior: StartupBehavior {
        didSet { d.set(startupBehavior.rawValue, forKey: "startupBehavior") }
    }
    // 覆盖 AppleLanguages，重启后生效（本地化在启动早期加载，无法热切换）。
    @Published var appLanguage: AppLanguage {
        didSet { d.set(appLanguage.rawValue, forKey: "appLanguage"); Self.applyLanguageOverride(appLanguage) }
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
    /// GPU（Metal）渲染终端；关闭则回退 CoreText 逐行 CPU 绘制。
    @Published var termGPURendering: Bool {
        didSet { d.set(termGPURendering, forKey: "termGPURendering") }
    }

    /// 默认下载目录（空=系统下载文件夹）。
    @Published var downloadDir: String {
        didSet { d.set(downloadDir, forKey: "downloadDir") }
    }
    /// 每次下载都询问保存位置。
    @Published var downloadAskEachTime: Bool {
        didSet { d.set(downloadAskEachTime, forKey: "downloadAskEachTime") }
    }
    /// 同时进行的传输（上传/下载共用）数量上限，超出排队。
    @Published var maxConcurrentTransfers: Int {
        didSet { d.set(maxConcurrentTransfers, forKey: "maxConcurrentTransfers") }
    }
    /// 暂停传输时是否释放并发名额：开启则暂停后空出的名额让排队任务补位（默认）；
    /// 关闭则暂停的任务仍占着名额，排队任务等其恢复或取消后才开跑（保持原有执行顺序）。
    @Published var pausedReleasesSlot: Bool {
        didSet { d.set(pausedReleasesSlot, forKey: "pausedReleasesSlot") }
    }
    /// 下载时是否自动弹出进度弹窗（默认开）；关闭后下载不弹窗，仅以「飞入左下角后台任务」的弧线动画提示。
    @Published var showDownloadDialog: Bool {
        didSet { d.set(showDownloadDialog, forKey: "showDownloadDialog") }
    }

    /// 资源告警：监控到 CPU/内存/磁盘持续高占用时发系统通知。
    @Published var resourceAlerts: Bool {
        didSet { d.set(resourceAlerts, forKey: "resourceAlerts") }
    }

    /// 关闭主窗口时隐藏到菜单栏（后台任务继续运行），而非退出。
    @Published var closeToTray: Bool {
        didSet { d.set(closeToTray, forKey: "closeToTray") }
    }

    /// 删除主机前弹出确认弹窗，避免误删。
    @Published var confirmHostDelete: Bool {
        didSet { d.set(confirmHostDelete, forKey: "confirmHostDelete") }
    }

    /// 永久隐藏监控面板的采集说明（在「设置 - 通用」中开启，持久化）。
    @Published var monitorNoticeHidden: Bool {
        didSet { d.set(monitorNoticeHidden, forKey: "monitorNoticeHidden") }
    }
    /// 本次启动已点「我已知晓」临时收起采集说明（不持久化，重启后恢复显示）。
    @Published var monitorNoticeAckedThisSession = false

    // 代码片段点击运行的行为；默认「每次询问」：首次点击弹「插入/运行」选择，可勾选记住后不再询问。
    @Published var snippetAction: SnippetAction {
        didSet { d.set(snippetAction.rawValue, forKey: "snippetAction") }
    }

    // RDP 连接成功后的打开方式；默认「每次询问」：弹「内嵌/新窗口」选择，可勾选记住后不再询问。
    @Published var rdpOpenMode: RDPOpenMode {
        didSet { d.set(rdpOpenMode.rawValue, forKey: "rdpOpenMode") }
    }

    // RDP 剪贴板双向同步（本地 ↔ 远端纯文本）；默认开。关闭后既不广播本地、也不接收远端剪贴板。
    @Published var rdpClipboardSync: Bool {
        didSet { d.set(rdpClipboardSync, forKey: "rdpClipboardSync") }
    }

    // 「新窗口」打开方式下，新 RDP 窗口是否默认进入全屏；默认开。仅 rdpOpenMode == .window 时生效。
    @Published var rdpWindowFullscreen: Bool {
        didSet { d.set(rdpWindowFullscreen, forKey: "rdpWindowFullscreen") }
    }

    private init() {
        startupBehavior = StartupBehavior(rawValue: d.string(forKey: "startupBehavior") ?? "") ?? .welcome
        defaultShell = DefaultShell(rawValue: d.string(forKey: "defaultShell") ?? "") ?? .auto
        closeConfirm = d.object(forKey: "closeConfirm") as? Bool ?? true
        editorMinimap = d.object(forKey: "editorMinimap") as? Bool ?? true
        termFont = d.string(forKey: "termFont") ?? ""
        termFontSize = d.object(forKey: "termFontSize") as? Int ?? 13
        termCursorStyle = d.string(forKey: "termCursorStyle") ?? "bar"
        termCursorBlink = d.object(forKey: "termCursorBlink") as? Bool ?? true
        termScrollback = d.object(forKey: "termScrollback") as? Int ?? 1000
        termGPURendering = d.object(forKey: "termGPURendering") as? Bool ?? true
        downloadDir = d.string(forKey: "downloadDir") ?? ""
        downloadAskEachTime = d.object(forKey: "downloadAskEachTime") as? Bool ?? false
        maxConcurrentTransfers = d.object(forKey: "maxConcurrentTransfers") as? Int ?? 2
        pausedReleasesSlot = d.object(forKey: "pausedReleasesSlot") as? Bool ?? true
        showDownloadDialog = d.object(forKey: "showDownloadDialog") as? Bool ?? true
        resourceAlerts = d.object(forKey: "resourceAlerts") as? Bool ?? true
        closeToTray = d.object(forKey: "closeToTray") as? Bool ?? false
        confirmHostDelete = d.object(forKey: "confirmHostDelete") as? Bool ?? true
        monitorNoticeHidden = d.object(forKey: "monitorNoticeHidden") as? Bool ?? false
        snippetAction = SnippetAction(rawValue: d.string(forKey: "snippetAction") ?? "") ?? .ask
        rdpOpenMode = RDPOpenMode(rawValue: d.string(forKey: "rdpOpenMode") ?? "") ?? .ask
        rdpClipboardSync = d.object(forKey: "rdpClipboardSync") as? Bool ?? true
        rdpWindowFullscreen = d.object(forKey: "rdpWindowFullscreen") as? Bool ?? false   // 默认不全屏（每次强制全屏体验不佳）
        appLanguage = AppLanguage(rawValue: d.string(forKey: "appLanguage") ?? "") ?? .zh
        Self.applyLanguageOverride(appLanguage)
    }

    /// 把界面语言写进 AppleLanguages（下次启动生效）；system 则移除覆盖、跟随系统。
    static func applyLanguageOverride(_ lang: AppLanguage) {
        let d = UserDefaults.standard
        if let code = lang.appleCode {
            d.set([code], forKey: "AppleLanguages")
        } else {
            d.removeObject(forKey: "AppleLanguages")
        }
    }

    /// 实际下载目录（展示 / 面板初始定位用）：设置为空则用系统下载文件夹。
    var resolvedDownloadDir: URL {
        if !downloadDir.isEmpty {
            return URL(fileURLWithPath: (downloadDir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private static let downloadBookmarkKey = "downloadDirBookmark"

    /// 记住用户在面板里选的自定义下载目录：存路径（展示用）+ 安全作用域书签。
    /// 沙盒下，仅凭路径字符串重建的 URL 拿不到写权限，必须靠书签在后续会话恢复授权；非沙盒无需书签。
    func setDownloadDir(_ url: URL) {
        downloadDir = url.path
        guard AppEnv.isSandboxed else { d.removeObject(forKey: Self.downloadBookmarkKey); return }
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
            d.set(data, forKey: Self.downloadBookmarkKey)
        } else {
            d.removeObject(forKey: Self.downloadBookmarkKey)
        }
    }

    /// 取「本次下载」的目标目录及其安全作用域访问：
    /// - 自定义目录：解析书签、开启安全作用域（沙盒必需），返回停止闭包，须在传输结束时调用。
    /// - 系统下载文件夹（downloadDir 为空）：由 downloads.read-write 授权，无需书签。
    /// 面板「每次询问」路径的 URL 自带进程内临时授权，不走这里。
    func acquireDownloadDirectory() -> (url: URL, release: () -> Void) {
        guard !downloadDir.isEmpty else { return (resolvedDownloadDir, {}) }
        if let data = d.data(forKey: Self.downloadBookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let started = url.startAccessingSecurityScopedResource()
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                            includingResourceValuesForKeys: nil, relativeTo: nil) {
                    d.set(fresh, forKey: Self.downloadBookmarkKey)
                }
                return (url, { if started { url.stopAccessingSecurityScopedResource() } })
            }
        }
        // 无可用书签（非沙盒直发，或旧数据）：路径直用（非沙盒可写任意路径）。
        return (resolvedDownloadDir, {})
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
