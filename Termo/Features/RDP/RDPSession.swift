import AppKit
import CoreGraphics
import SwiftUI

/// 用户对证书弹窗的选择：拒绝连接 / 仅本次接受 / 始终信任此电脑。
enum RDPCertDecision { case reject, once, trust }

/// 待用户确认的证书信任请求（首连或证书变更时弹窗用）。respond 回传用户选择。
struct RDPCertPrompt: Identifiable {
    let id = UUID()
    let host: String
    let port: Int
    let fingerprint: String
    let subject: String?
    let issuer: String?
    let changed: Bool            // true=与已信任指纹不一致，弹更强警告
    let oldFingerprint: String?
    let respond: (RDPCertDecision) -> Void
}

/// 连接日志一行（连接面板「实时日志」用）。level：0=信息 1=警告 2=错误。
struct RDPLogLine: Identifiable {
    let id = UUID()
    let time: String
    let message: String
    let level: Int
}

/// 连接进度步骤（由会话 phase 推导，不解析日志字符串，避免脆弱）。
struct RDPConnectStep: Identifiable {
    enum State { case pending, running, success, failure }
    let id = UUID()
    let title: String
    var state: State
}

/// 一个 RDP 远程桌面会话的宿主状态。
///
/// 经 ObjC 桥 `TermoRDPSession` → 纯 C 层 `TermoRDPCore` 驱动 FreeRDP：后台事件循环线程跑
/// `freerdp_connect`，每帧 BGRA 缓冲经 delegate 回到主线程，转成 `CGImage` 供 `RDPSessionView` 显示。
final class RDPSession: NSObject, ObservableObject, TermoRDPSessionDelegate {
    enum Phase: Equatable {
        case pending          // 尚未发起连接
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    let host: Host
    let config: RDPConnection
    @Published private(set) var phase: Phase = .pending
    @Published private(set) var image: CGImage? = nil   // 最新一帧（主线程更新）
    @Published var certPrompt: RDPCertPrompt? = nil      // 非 nil 时叠加证书信任弹窗
    @Published private(set) var logs: [RDPLogLine] = []  // 连接日志（连接面板展示）
    @Published private(set) var ready: Bool = false      // 首帧沉降后置真：通知连接弹窗可进入（避免进入瞬间闪半成品桌面）
    private var lastCanvas: CGSize? = nil                // 最近一次连接画布尺寸（重试复用）
    private var firstFrameScheduled = false              // 已为首帧安排沉降，防重复调度

    private var session: TermoRDPSession?

    init(host: Host) {
        self.host = host
        self.config = host.rdp ?? RDPConnection()
        super.init()
    }

    /// 发起连接（幂等：已在连接/已连接则忽略）。按画布（窗口内容区，points）换算远端桌面像素分辨率，
    /// 使画面 1:1 填满窗口、无黑边、清晰。
    func connect(canvas: CGSize) {
        guard session == nil else { return }
        guard let t = Self.targetPixelSize(canvas) else { return }
        lastCanvas = canvas
        ready = false
        firstFrameScheduled = false
        phase = .connecting
        let s = TermoRDPSession(host: config.host, port: Int32(config.port),
                                username: config.user, password: config.password,
                                domain: config.domain,
                                width: Int32(t.w), height: Int32(t.h))
        s.delegate = self
        session = s
        lastSent = t
        s.connect()
    }

    /// 画布尺寸（points）→ 远端桌面像素尺寸：
    /// 按 Retina backing 缩放取真实像素 → 1:1 清晰；保宽高比缩到 [640×480, 2560×1600] 内（只缩不放）→
    /// 远端宽高比恒等于画布、scaledToFit 满铺无黑边；宽高向下对齐 8。
    static func targetPixelSize(_ canvas: CGSize) -> (w: Int, h: Int)? {
        guard canvas.width >= 100, canvas.height >= 100 else { return nil }
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        var w = Double(canvas.width) * scale
        var h = Double(canvas.height) * scale
        let r = min(1.0, 2560.0 / w, 1600.0 / h)   // 超限则保比例整体缩小
        w *= r; h *= r
        let wi = max(640, Int(w.rounded(.down))) / 8 * 8
        let hi = max(480, Int(h.rounded(.down))) / 8 * 8
        return (wi, hi)
    }

    /// 请求断开；底层线程结束后经 didChangeState(.disconnected) 收尾，会话对象在本对象释放时 free。
    func disconnect() {
        stopClipboardSync()
        session?.disconnect()
    }

    /// 同步关闭并 join 后台线程（退出 App 前用）。返回后底层线程已收尾，不会在进程退出时残留/互斥。
    func shutdown() {
        stopClipboardSync()
        session?.shutdown()
        session = nil
    }

    // MARK: - 鼠标输入（x/y 为远端桌面像素坐标）
    // 仅在已连接时下发；否则 FreeRDP 会对断开后的输入狂刷 "input functions called after the session terminated"。
    private var isConnected: Bool { if case .connected = phase { return true }; return false }
    func sendMouseMove(_ x: Int, _ y: Int) {
        guard isConnected else { return }
        session?.sendMouseMoveX(Int32(x), y: Int32(y))
    }
    func sendMouseButton(_ button: Int, down: Bool, x: Int, y: Int) {
        guard isConnected else { return }
        session?.sendMouseButton(Int32(button), down: down, x: Int32(x), y: Int32(y))
    }
    func sendMouseWheel(_ delta: Int, x: Int, y: Int) {
        guard isConnected else { return }
        session?.sendMouseWheel(Int32(delta), x: Int32(x), y: Int32(y))
    }

    // MARK: - 键盘输入（keyCode=macOS 虚拟键码；mask=修饰键掩码 TermoRDPModMask）
    func sendKey(_ keyCode: Int, down: Bool) {
        guard isConnected else { return }
        session?.sendKey(Int32(keyCode), down: down)
    }
    func sendModifiers(_ mask: Int) {
        guard isConnected else { return }
        session?.sendModifiers(Int32(mask))
    }

    // MARK: - 动态分辨率（窗口缩放自适应）
    private var resizeWork: DispatchWorkItem?
    private var lastSent: (w: Int, h: Int)?
    /// 窗口尺寸变化时调用。拖动期间只本地缩放（SwiftUI scaledToFit），停止后合并成一次远端 resize：
    /// 防抖 0.5s + 最小变化 32px（避免把中间布局过程当最终尺寸、狂发 DisplayControl）。
    /// 通道/能力未就绪时底层会缓存目标尺寸，待 DisplayControlCaps 到达自动补发。
    func requestResize(canvas: CGSize) {
        guard case .connected = phase, let t = Self.targetPixelSize(canvas) else { return }
        if let l = lastSent, abs(l.w - t.w) < 32, abs(l.h - t.h) < 32 { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.session?.resize(toWidth: Int32(t.w), height: Int32(t.h))
            self?.lastSent = t
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - TermoRDPSessionDelegate（桥已派发到主线程）
    func rdpSession(_ session: TermoRDPSession, didChangeState state: Int, message: String?) {
        switch state {
        case 0: phase = .connecting
        case 1: phase = .connected; startClipboardSync()
        case 2: phase = .disconnected; stopClipboardSync()
        default: phase = .failed(message ?? String(localized: "连接失败")); stopClipboardSync()
        }
    }

    // MARK: - 剪贴板同步（双向纯文本）
    private var pbTimer: Timer?
    private var pbLastCount = NSPasteboard.general.changeCount
    private var pbSuppressCount = -1   // 远端写入本地时记下该 changeCount，避免回环再广播回远端

    /// 剪贴板同步是否开启（设置项，可运行中切换）。
    private var clipboardSyncOn: Bool { AppSettings.shared.rdpClipboardSync }

    /// 连接成功即开始：若开启，先把当前本地文本通告远端；再每 0.5s 轮询本地剪贴板变化（NSPasteboard 无变更通知）。
    /// 定时器始终运行，三个动作点各自按开关门控，从而支持运行中实时开/关。
    private func startClipboardSync() {
        guard pbTimer == nil else { return }
        pbLastCount = NSPasteboard.general.changeCount
        if clipboardSyncOn, let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
            self.session?.offerClipboardText(s)
        }
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollLocalClipboard()
        }
        RunLoop.main.add(t, forMode: .common)   // 拖动/滚动等跟踪模式下也轮询
        pbTimer = t
    }

    private func stopClipboardSync() {
        pbTimer?.invalidate()
        pbTimer = nil
    }

    private func pollLocalClipboard() {
        guard clipboardSyncOn else { return }
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != pbLastCount else { return }
        pbLastCount = count
        if count == pbSuppressCount { return }   // 这次变化来自远端回写，不再广播回去
        session?.offerClipboardText(pb.string(forType: .string))
    }

    /// 远端剪贴板文本 → 本地（桥已派发到主线程）。记下 changeCount 以便轮询跳过本次写入，避免回环。
    func rdpSession(_ session: TermoRDPSession, didReceiveClipboardText text: String) {
        guard clipboardSyncOn else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pbSuppressCount = pb.changeCount
        pbLastCount = pb.changeCount
    }

    func rdpSession(_ session: TermoRDPSession, didReceiveFrame pixels: Data,
                    width: Int32, height: Int32, stride: Int32, bpp: Int32) {
        image = Self.makeImage(pixels, Int(width), Int(height), Int(stride), Int(bpp))
        // 首帧后短暂沉降，让服务器把整桌面逐块画完再通知「可进入」，避免进入瞬间闪黑屏/残缺画面。
        if !firstFrameScheduled {
            firstFrameScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, case .connected = self.phase, self.image != nil else { return }
                self.ready = true
            }
        }
    }

    /// 证书信任校验（桥已派发到主线程）。已永久信任且指纹一致 → 静默放行；否则弹窗让用户决定。
    /// completion：0=拒绝、1=永久信任、2=仅本次。本工程不用 FreeRDP known_hosts，永久信任写本地库后仍回 2。
    /// 显式 selector：这个超长签名的 @objc 自动推断不可靠，不匹配会导致桥层 respondsToSelector 失败、
    /// 静默走「未实现→默认放行」兜底（表现为弹窗不出现却直接连上）。固定 selector 以保证桥层能调到本方法。
    @objc(rdpSession:verifyCertificateForHost:port:commonName:subject:issuer:fingerprint:changed:oldSubject:oldIssuer:oldFingerprint:completion:)
    func rdpSession(_ session: TermoRDPSession, verifyCertificateForHost host: String, port: Int32,
                    commonName: String?, subject: String?, issuer: String?, fingerprint: String?,
                    changed: Bool, oldSubject: String?, oldIssuer: String?, oldFingerprint: String?,
                    completion: @escaping (Int) -> Void) {
        let fp = fingerprint ?? ""
        let p = Int(port)
        if RDPCertTrustStore.shared.isTrusted(host: host, port: p, fingerprint: fp) {
            appendLog(String(localized: "服务器证书已信任，继续连接"))
            completion(2); return   // 已信任，无需打扰
        }
        appendLog(changed ? String(localized: "服务器证书已更改，等待用户确认…") : String(localized: "未信任的服务器证书，等待用户确认…"), level: 1)
        certPrompt = RDPCertPrompt(host: host, port: p, fingerprint: fp,
                                   subject: subject, issuer: issuer,
                                   changed: changed, oldFingerprint: oldFingerprint) { [weak self] decision in
            self?.certPrompt = nil
            switch decision {
            case .reject:
                self?.appendLog(String(localized: "用户已拒绝证书，连接取消"), level: 2)
                completion(0)
            case .once:
                self?.appendLog(String(localized: "用户接受证书（仅本次），继续连接"))
                completion(2)
            case .trust:
                self?.appendLog(String(localized: "用户选择始终信任此电脑，继续连接"))
                RDPCertTrustStore.shared.trust(host: host, port: p, fingerprint: fp,
                                               subject: subject, issuer: issuer)
                completion(2)
            }
        }
    }

    /// 连接日志（桥已派发到主线程）。显式 selector，规避可选协议方法 @objc 自动推断不稳。
    @objc(rdpSession:didLog:level:)
    func rdpSession(_ session: TermoRDPSession, didLog text: String, level: Int) {
        appendLog(Self.localizeCoreLog(text), level: level)
    }

    /// C 桥接层（FreeRDP）用中文常量打日志、显示在连接面板，此处按已知集合本地化；动态行按前缀处理。
    private static func localizeCoreLog(_ text: String) -> String {
        switch text {
        case "初始化连接参数…":              return String(localized: "初始化连接参数…")
        case "图形子系统已就绪，连接成功":      return String(localized: "图形子系统已就绪，连接成功")
        case "图形管线已启用（全彩）":         return String(localized: "图形管线已启用（全彩）")
        case "显示控制通道就绪（支持动态分辨率）": return String(localized: "显示控制通道就绪（支持动态分辨率）")
        case "正在协商安全层并建立连接…":       return String(localized: "正在协商安全层并建立连接…")
        case "正在验证服务器证书…":           return String(localized: "正在验证服务器证书…")
        case "连接失败（认证失败或服务器不可达）": return String(localized: "连接失败（认证失败或服务器不可达）")
        case "连接已断开":                  return String(localized: "连接已断开")
        default: break
        }
        if text.hasPrefix("开始连接 ") {
            return String(localized: "开始连接 \(String(text.dropFirst("开始连接 ".count)))")
        }
        if text.hasPrefix("连接启动失败 ("), text.hasSuffix(")") {
            return String(localized: "连接启动失败 (\(String(text.dropFirst("连接启动失败 (".count).dropLast())))")
        }
        return text
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// 追加一行连接日志（主线程）。
    func appendLog(_ message: String, level: Int = 0) {
        logs.append(RDPLogLine(time: Self.logTimeFormatter.string(from: Date()), message: message, level: level))
    }

    /// 重试连接：释放旧底层会话（join 其线程）、清空帧与日志，按上次画布尺寸重连。
    func retry() {
        session = nil
        image = nil
        logs = []
        ready = false
        firstFrameScheduled = false
        phase = .pending
        if let c = lastCanvas { connect(canvas: c) }
    }

    // MARK: - 连接面板（步骤 + 状态，均由 phase 推导）

    /// 连接步骤与状态。三步覆盖关键阶段；细节由实时日志补充。
    var connectSteps: [RDPConnectStep] {
        let titles = [String(localized: "初始化配置"), String(localized: "建立安全连接"), String(localized: "连接成功")]
        let states: [RDPConnectStep.State]
        switch phase {
        case .pending:      states = [.running, .pending, .pending]
        case .connecting:   states = [.success, .running, .pending]
        case .connected:    states = [.success, .success, .success]
        case .failed:       states = [.success, .failure, .pending]
        case .disconnected: states = [.success, .failure, .pending]
        }
        return zip(titles, states).map { RDPConnectStep(title: $0, state: $1) }
    }

    var connectStatusText: String {
        switch phase {
        case .pending, .connecting: return String(localized: "连接中…")
        case .connected:            return String(localized: "连接成功")
        case .failed:               return String(localized: "连接失败")
        case .disconnected:         return String(localized: "已断开")
        }
    }

    /// gdi 帧缓冲 → CGImage。按实际每像素字节数选位序/位深（对齐官方 Mac/iOS 客户端 mac_create_bitmap_context）：
    /// - bpp==2（RGB16/RGB565）：bitsPerComponent=5、bitsPerPixel=16、byteOrder16Little
    /// - 否则（BGRX32）：bitsPerComponent=8、bitsPerPixel=32、byteOrder32Little
    /// 二者均 noneSkipFirst：忽略最高位/alpha，避免整帧透明。服务器降级到 RGB16 且 resize 后尤需走 16bpp 分支，
    /// 否则用 32bpp 步幅解读 16bpp 数据会把每行拆成两行 → 画面撕裂成双桌面。
    private static func makeImage(_ data: Data, _ w: Int, _ h: Int, _ stride: Int, _ bpp: Int) -> CGImage? {
        guard w > 0, h > 0, stride > 0, data.count >= h * stride else { return nil }
        let order: CGBitmapInfo = bpp == 2 ? .byteOrder16Little : .byteOrder32Little
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | order.rawValue)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: bpp == 2 ? 5 : 8, bitsPerPixel: bpp == 2 ? 16 : 32,
                       bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
