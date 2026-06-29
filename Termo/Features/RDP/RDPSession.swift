import AppKit
import CoreGraphics
import SwiftUI

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
        session?.disconnect()
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
        case 1: phase = .connected
        case 2: phase = .disconnected
        default: phase = .failed(message ?? "连接失败")
        }
    }

    func rdpSession(_ session: TermoRDPSession, didReceiveFrame pixels: Data,
                    width: Int32, height: Int32, stride: Int32, bpp: Int32) {
        image = Self.makeImage(pixels, Int(width), Int(height), Int(stride), Int(bpp))
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
