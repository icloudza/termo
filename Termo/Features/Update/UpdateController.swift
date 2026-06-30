import AppKit
import Combine
import Foundation

// MARK: - 状态机模型（渠道无关）

/// 更新流程的高层 UI 状态。具体进度数字/版本信息/发行说明放在 UpdateController 的独立 @Published 字段，
/// 便于异步增量更新（如发行说明下载完成后单独回填），不必整体替换枚举关联值。
enum UpdatePhase: Equatable {
    case idle            // 空闲（无面板）
    case checking        // 正在检查
    case upToDate        // 已是最新
    case found           // 发现新版本，待用户决定
    case downloading     // 下载中
    case extracting      // 解压中
    case readyToInstall  // 下载完成，待重启安装
    case installing      // 安装中（即将重启）
    case error(String)   // 出错
}

/// 发现的新版本信息（取自 appcast item）。
struct UpdateInfo: Equatable {
    var displayVersion: String   // 展示版本，如 "0.9.2"
    var build: String            // CFBundleVersion，如 "28"
    var dateString: String?      // 发布日期文案
    var isCritical: Bool         // 关键更新
}

/// 用户在「发现新版本 / 待安装」面板上的选择。
enum UpdateUserChoice { case install, skip, later }

// MARK: - 渠道后端协议

/// 更新后端：Developer ID 走 Sparkle（应用内自动更新）；Mac App Store 走系统商店。
/// 后端通过 weak 持有的 UpdateController 回写 @Published 状态，UI 只观察 Controller。
@MainActor
protocol UpdateBackend: AnyObject {
    /// 是否支持「应用内」自动更新（Dev ID=true）。MAS=false，仅能跳转 App Store。
    var supportsInApp: Bool { get }
    /// 自动后台检查开关（映射 Sparkle automaticallyChecksForUpdates；MAS 无意义）。
    var automaticChecks: Bool { get set }
    /// 上次检查时间（Sparkle 持久化；MAS 为 nil）。
    var lastCheckDate: Date? { get }

    /// App 启动后调用一次：启动 updater 调度（Dev ID）。
    func startup()
    /// 检查更新。userInitiated=true 为用户手动点击（会展示「检查中/已是最新」面板）。
    func check(userInitiated: Bool)
    /// 用户在面板上的选择（发现新版本 / 待安装重启）。
    func respond(_ choice: UpdateUserChoice)
    /// 取消进行中的检查 / 下载。
    func cancel()
    /// 确认并关闭「已是最新 / 出错」提示。
    func acknowledge()
    /// 静默结束当前检查会话：内联入口「已是最新」不弹窗，但仍须结束 Sparkle 会话，
    /// 否则其 sessionInProgress 不复位，下次检查报「called but .sessionInProgress == YES」。
    func concludeSilently()
}

// MARK: - 控制器（UI 唯一观察源）

/// 自动更新的总控：持有渠道后端、发布 UI 状态、转发用户操作、驱动更新面板的显示/隐藏。
/// 三处入口（关于窗口 / 托盘 / 设置页）都只与本控制器交互，不关心运行渠道。
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    // —— 观察态 ——
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var info: UpdateInfo?            // found/下载/安装期间有效
    @Published private(set) var releaseNotesHTML: String?    // 发行说明（可能异步回填）
    @Published private(set) var downloadReceived: UInt64 = 0
    @Published private(set) var downloadTotal: UInt64 = 0
    @Published private(set) var extractFraction: Double = 0
    @Published private(set) var lastCheckDate: Date?

    /// 自动检查开关：UI 绑定。set 透传后端并刷新展示。
    @Published var automaticChecks: Bool = false {
        didSet {
            guard !syncingAuto, backend.automaticChecks != automaticChecks else { return }
            backend.automaticChecks = automaticChecks
        }
    }
    private var syncingAuto = false   // 防 didSet 与后端回灌互相触发

    var supportsInApp: Bool { backend.supportsInApp }

    private let backend: UpdateBackend

    private init() {
        #if TERMO_MAS
        backend = AppStoreUpdateBackend()
        #else
        backend = SparkleUpdateBackend()
        #endif
        // 双向绑定后端 → 控制器（Sparkle 后端在 init 里设置）。
        (backend as? ControllerBindable)?.bind(self)
        refreshFromBackend()
    }

    /// App 启动后调用：启动 updater 调度。
    func startup() {
        backend.startup()
        refreshFromBackend()
    }

    // —— 用户操作 ——

    // checking / upToDate 是否在独立窗口呈现。内联入口（关于/设置页）置 false——那里已有内联进度与
    // 「已是最新」状态，无需再弹窗；只有发现更新/下载/安装/出错才需要完整面板。菜单/托盘入口为 true。
    private var surfaceTransient = true

    /// 手动检查更新。surfaceTransient=false 时「检查中/已是最新」不弹独立窗口（交由内联控件展示）。
    func checkForUpdates(surfaceTransient: Bool = true) {
        self.surfaceTransient = surfaceTransient
        backend.check(userInitiated: true)
    }

    func install() { backend.respond(.install) }
    func skip()    { backend.respond(.skip) }
    func later()   { backend.respond(.later); dismissPanel() }
    func cancel()  { backend.cancel() }
    func acknowledge() { backend.acknowledge() }

    /// 关闭面板（用户点 ✕ 或「稍后」）。仅隐藏窗口；后端若有待回复，由 later()/acknowledge() 负责。
    func dismissPanel() { UpdateWindowPresenter.shared.dismiss() }

    /// 用户点面板右上角 ✕：按当前阶段做最合理的收尾（取消进行中 / 视作稍后 / 确认提示）。
    func userClosedPanel() {
        switch phase {
        case .checking, .downloading:   cancel()        // 中断进行中的检查/下载
        case .found, .readyToInstall:   later()         // 视作「稍后」，保留更新待下次提醒
        case .upToDate, .error:         acknowledge()   // 确认并关闭提示
        case .extracting, .installing:  dismissPanel()  // 不可中断阶段，仅隐藏窗口
        case .idle:                     dismissPanel()
        }
    }

    // —— 供后端回写（仅主线程）——

    func apply(_ newPhase: UpdatePhase) {
        phase = newPhase
        switch newPhase {
        case .idle:
            UpdateWindowPresenter.shared.dismiss()
        case .checking:
            // 检查中：内联入口不弹窗（内联控件自带 spinner），其它入口照常弹。
            if surfaceTransient { UpdateWindowPresenter.shared.present() }
            else { UpdateWindowPresenter.shared.dismiss() }
        case .upToDate:
            if surfaceTransient {
                UpdateWindowPresenter.shared.present()
            } else {
                // 内联入口：不弹窗，但必须结束 Sparkle 会话，否则下次检查会因 sessionInProgress 失败。
                UpdateWindowPresenter.shared.dismiss()
                backend.concludeSilently()
            }
        case .found, .downloading, .extracting, .readyToInstall, .installing, .error:
            UpdateWindowPresenter.shared.present()
        }
        refreshFromBackend()
    }

    func setInfo(_ i: UpdateInfo?) { info = i }
    func setReleaseNotes(_ html: String?) { releaseNotesHTML = html }
    func setDownload(received: UInt64, total: UInt64) {
        downloadReceived = received; downloadTotal = total
    }
    func setExtract(_ f: Double) { extractFraction = f }

    /// 从后端回灌自动检查开关与上次检查时间（不反向触发 set）。
    func refreshFromBackend() {
        syncingAuto = true
        automaticChecks = backend.automaticChecks
        syncingAuto = false
        lastCheckDate = backend.lastCheckDate
    }

    // —— 展示辅助 ——

    /// 进度（0…1）：下载阶段用字节比，解压阶段用 extractFraction。
    var progressFraction: Double {
        switch phase {
        case .downloading:
            guard downloadTotal > 0 else { return 0 }
            return min(1, Double(downloadReceived) / Double(downloadTotal))
        case .extracting: return extractFraction
        default: return 0
        }
    }

    /// 进度文案，如「3.2 MB / 12 MB」。
    var progressLabel: String {
        guard downloadTotal > 0 else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: Int64(downloadReceived))) / \(f.string(fromByteCount: Int64(downloadTotal)))"
    }
}

/// 后端若需回握控制器（Sparkle）则实现此协议。
@MainActor
protocol ControllerBindable: AnyObject {
    func bind(_ controller: UpdateController)
}

// MARK: - Mac App Store 后端

/// MAS 渠道：不能应用内自更新（沙盒禁止 + 审核拒），点「检查更新」跳转 App Store 更新页。
@MainActor
final class AppStoreUpdateBackend: UpdateBackend {
    var supportsInApp: Bool { false }
    var automaticChecks: Bool {
        get { true }      // App Store 由系统自动更新，恒为开
        set {}
    }
    var lastCheckDate: Date? { nil }

    func startup() {}

    func check(userInitiated: Bool) {
        // 暂用「更新」页（上架拿到 App ID 后改为 macappstore://apps.apple.com/app/id<APPID>）。
        if let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        }
    }

    func respond(_ choice: UpdateUserChoice) {}
    func cancel() {}
    func acknowledge() {}
    func concludeSilently() {}
}
