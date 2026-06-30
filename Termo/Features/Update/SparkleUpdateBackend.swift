#if !TERMO_MAS
import AppKit
import Foundation
import Sparkle

/// Developer ID 渠道的更新后端：包裹 SPUUpdater，并**自任 SPUUserDriver** 接管全部更新 UI。
/// 不用 Sparkle 自带的标准 UI（原生 NSAlert 风格），而是把每个回调翻译成 UpdateController 的状态，
/// 由我们的 ThemedXxx 面板渲染（方案 B：禁原生模态，统一观感）。
///
/// 线程：Sparkle 在主线程派发 user driver 回调，故整类 @MainActor；reply 块也在主线程存取与调用。
@MainActor
final class SparkleUpdateBackend: NSObject, UpdateBackend, ControllerBindable, SPUUserDriver {

    private var updater: SPUUpdater!
    private weak var controller: UpdateController?
    private var started = false

    // —— 待回复的 Sparkle 回调块（同一时刻至多一类有效）——
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?     // 发现新版本：install/skip/dismiss
    private var cancellation: (() -> Void)?                      // 检查/下载可取消
    private var acknowledgement: (() -> Void)?                   // 已是最新/出错的确认
    private var readyContinuation: CheckedContinuation<SPUUserUpdateChoice, Never>?  // 待安装重启
    private var didStartDownload = false                        // 仅用于进度文案重置

    override init() {
        super.init()
        // hostBundle/applicationBundle 均为主包；userDriver=self；feedURL/公钥由 Info.plist 提供。
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
    }

    func bind(_ controller: UpdateController) { self.controller = controller }

    // MARK: UpdateBackend

    var supportsInApp: Bool { true }

    var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    var lastCheckDate: Date? { updater?.lastUpdateCheckDate }

    func startup() {
        guard !started else { return }
        do {
            try updater.start()
            started = true
        } catch {
            NSLog("[Update] Sparkle 启动失败：\(error.localizedDescription)")
        }
    }

    func check(userInitiated: Bool) {
        startup()   // 幂等，确保已启动
        if userInitiated {
            updater.checkForUpdates()
        } else {
            updater.checkForUpdatesInBackground()
        }
    }

    func respond(_ choice: UpdateUserChoice) {
        let mapped: SPUUserUpdateChoice
        switch choice {
        case .install: mapped = .install
        case .skip:    mapped = .skip
        case .later:   mapped = .dismiss
        }
        if let reply = foundReply {
            foundReply = nil
            reply(mapped)
        } else if let cont = readyContinuation {
            readyContinuation = nil
            // 待安装阶段无「跳过」语义：skip 视作稍后。
            cont.resume(returning: choice == .install ? .install : .dismiss)
        }
    }

    func cancel() {
        if let c = cancellation {
            cancellation = nil
            c()
        }
        controller?.apply(.idle)
    }

    func acknowledge() {
        if let a = acknowledgement {
            acknowledgement = nil
            a()
        }
        controller?.apply(.idle)
    }

    /// 静默结束会话（内联「已是最新」用）：只触发 Sparkle 的确认块以复位 sessionInProgress，
    /// 不主动 apply(.idle)——后续 Sparkle 会回调 dismissUpdateInstallation 自然收尾。
    func concludeSilently() {
        if let a = acknowledgement {
            acknowledgement = nil
            a()
        }
        cancellation = nil
    }

    // MARK: - SPUUserDriver

    /// 首次运行的授权请求：不弹原生框，直接默认「开启自动检查、不上报系统画像」。用户可在设置页随时关。
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
        controller?.refreshFromBackend()
    }

    /// 用户手动检查：显示「检查中」并允许取消。
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        controller?.apply(.checking)
    }

    /// 发现新版本：填版本信息 + 行内发行说明（若有），等待用户选择。
    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundReply = reply
        controller?.setInfo(UpdateInfo(
            displayVersion: appcastItem.displayVersionString,
            build: appcastItem.versionString,
            dateString: appcastItem.dateString,
            isCritical: appcastItem.isCriticalUpdate))
        // 行内 HTML 发行说明（appcast 的 <description>）；若改用 releaseNotesLink 则稍后异步回填。
        if let desc = appcastItem.itemDescription, !desc.isEmpty {
            controller?.setReleaseNotes(desc)
        } else {
            controller?.setReleaseNotes(nil)
        }
        controller?.apply(.found)
    }

    /// 异步下载到的发行说明（appcast 用 <sparkle:releaseNotesLink> 时）。
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        let enc = encoding(from: downloadData.textEncodingName)
        if let html = String(data: downloadData.data, encoding: enc)
            ?? String(data: downloadData.data, encoding: .utf8) {
            controller?.setReleaseNotes(html)
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // 发行说明拉取失败不影响更新本身：面板回退到「无发行说明」文案。
        controller?.setReleaseNotes(nil)
    }

    /// 用户手动检查但已是最新。
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        self.acknowledgement = acknowledgement
        controller?.apply(.upToDate)
    }

    /// updater 出错（网络/校验等）。
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        self.acknowledgement = acknowledgement
        controller?.apply(.error(error.localizedDescription))
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        didStartDownload = true
        controller?.setDownload(received: 0, total: 0)
        controller?.apply(.downloading)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller?.setDownload(received: 0, total: expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let c = controller
        let received = (c?.downloadReceived ?? 0) + length
        c?.setDownload(received: received, total: c?.downloadTotal ?? 0)
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil     // 解压阶段不可取消
        controller?.setExtract(0)
        controller?.apply(.extracting)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        controller?.setExtract(progress)
        controller?.apply(.extracting)
    }

    /// 下载/解压完成，等待用户确认重启安装（仅 async 形式，用 continuation 桥接面板按钮）。
    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        await withCheckedContinuation { (cont: CheckedContinuation<SPUUserUpdateChoice, Never>) in
            self.readyContinuation = cont
            self.controller?.apply(.readyToInstall)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        controller?.apply(.installing)
    }

    /// 安装并重启完成（一般在新版本进程里被调用）：立即确认，复位面板。
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        controller?.apply(.idle)
    }

    /// Sparkle 要求关闭一切更新 UI（流程结束/被取消）。
    func dismissUpdateInstallation() {
        foundReply = nil
        cancellation = nil
        acknowledgement = nil
        if let cont = readyContinuation {   // 异常路径兜底，避免 continuation 泄漏
            readyContinuation = nil
            cont.resume(returning: .dismiss)
        }
        controller?.apply(.idle)
    }

    /// 可选：把更新窗口带到前台。
    func showUpdateInFocus() {
        UpdateWindowPresenter.shared.present()
    }

    // MARK: - 工具

    private func encoding(from name: String?) -> String.Encoding {
        guard let name else { return .utf8 }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return .utf8 }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
#endif
