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

    /// 发起连接（幂等：已在连接/已连接则忽略）。desktopWidth/Height 为远端桌面分辨率，
    /// 由视图按窗口实际尺寸传入，使画面 1:1 填满窗口、无黑边、清晰；非法尺寸回退到配置值。
    func connect(desktopWidth: Int, desktopHeight: Int) {
        guard session == nil else { return }
        let w = desktopWidth >= 640 ? (desktopWidth & ~1) : config.width   // 偶数、最小 640
        let h = desktopHeight >= 480 ? (desktopHeight & ~1) : config.height
        phase = .connecting
        let s = TermoRDPSession(host: config.host, port: Int32(config.port),
                                username: config.user, password: config.password,
                                domain: config.domain,
                                width: Int32(w), height: Int32(h))
        s.delegate = self
        session = s
        s.connect()
    }

    /// 请求断开；底层线程结束后经 didChangeState(.disconnected) 收尾，会话对象在本对象释放时 free。
    func disconnect() {
        session?.disconnect()
    }

    // MARK: - 鼠标输入（x/y 为远端桌面像素坐标）
    func sendMouseMove(_ x: Int, _ y: Int) {
        session?.sendMouseMoveX(Int32(x), y: Int32(y))
    }
    func sendMouseButton(_ button: Int, down: Bool, x: Int, y: Int) {
        session?.sendMouseButton(Int32(button), down: down, x: Int32(x), y: Int32(y))
    }
    func sendMouseWheel(_ delta: Int, x: Int, y: Int) {
        session?.sendMouseWheel(Int32(delta), x: Int32(x), y: Int32(y))
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

    func rdpSession(_ session: TermoRDPSession, didReceiveFrame bgra: Data,
                    width: Int32, height: Int32, stride: Int32) {
        image = Self.makeImage(bgra, Int(width), Int(height), Int(stride))
    }

    /// BGRA32 缓冲 → CGImage。FreeRDP PIXEL_FORMAT_BGRA32 内存序为 B,G,R,A；
    /// byteOrder32Little + noneSkipFirst 按 XRGB 解读、忽略 alpha（避免 alpha=0 时整帧透明）。
    private static func makeImage(_ data: Data, _ w: Int, _ h: Int, _ stride: Int) -> CGImage? {
        guard w > 0, h > 0, data.count >= h * stride else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
