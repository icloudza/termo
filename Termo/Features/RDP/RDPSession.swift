import SwiftUI

/// 一个 RDP 远程桌面会话的宿主状态。
///
/// 当前为脚手架阶段：仅承载主机/配置与连接状态占位。真正的渲染内核
/// （FreeRDP，经 `TermoRDPSession` ObjC 桥）将在后续阶段接入到这里——
/// `connect()` 起后台事件循环线程跑 `freerdp_connect`，帧回调驱动 `RDPSurfaceView`。
@MainActor
final class RDPSession: ObservableObject {
    enum Phase: Equatable {
        case pending          // 渲染内核尚未接入（脚手架占位）
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    let host: Host
    let config: RDPConnection
    @Published private(set) var phase: Phase = .pending

    init(host: Host) {
        self.host = host
        self.config = host.rdp ?? RDPConnection()
    }

    /// 后续阶段：启动 TermoRDPSession 后台线程并连接。当前为接缝：自检 FreeRDP 桥已链接。
    func connect() {
        // 阶段 C 接缝：引用 ObjC 桥（确保 FreeRDP 静态库被链接、Swift↔ObjC 桥接成立）。
        // 下一步替换为：实例化 TermoRDPSession、设 delegate、起事件循环线程，phase=.connecting→.connected/.failed。
        NSLog("[rdp] FreeRDP %@ linked OK", TermoRDPSession.freerdpVersion())
    }

    /// 断开并释放底层会话。当前仅切换状态占位。
    func disconnect() {
        guard phase != .disconnected else { return }
        phase = .disconnected
        // TODO(阶段 C)：freerdp_disconnect + 结束事件循环线程
    }
}
