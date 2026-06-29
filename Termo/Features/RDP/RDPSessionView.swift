import SwiftUI

/// RDP 远程桌面标签页：显示 FreeRDP 实时帧；未连通时显示状态面板。
struct RDPSessionView: View {
    @ObservedObject var session: RDPSession
    @ObservedObject private var theme = ThemeManager.shared

    private var cfg: RDPConnection { session.config }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = session.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.low)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    RDPMouseLayer(remoteW: img.width, remoteH: img.height,
                                  onMove: { session.sendMouseMove($0, $1) },
                                  onButton: { session.sendMouseButton($0, down: $1, x: $2, y: $3) },
                                  onWheel: { session.sendMouseWheel($0, x: $1, y: $2) })
                }
                if shouldShowStatus { statusPanel }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 首次拿到窗口尺寸即按其分辨率连接（幂等，只连一次），使画面填满窗口、无黑边。
            .onAppear { connectIfReady(geo.size) }
            .onChange(of: geo.size) { _, new in
                connectIfReady(new)                 // 首次：按尺寸连接
                session.requestResize(canvas: new)  // 之后：拖停后合并发一次远端 resize
            }
        }
        .onDisappear { session.disconnect() }
    }

    private func connectIfReady(_ size: CGSize) {
        guard size.width > 200, size.height > 200 else { return }
        session.connect(canvas: size)
    }

    /// 已连接且已出帧时不盖状态面板。
    private var shouldShowStatus: Bool {
        if case .connected = session.phase, session.image != nil { return false }
        return true
    }

    private var statusPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: statusIcon)
                .font(.system(size: 32))
                .foregroundStyle(Pal.mauve)
                .frame(width: 72, height: 72)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 6) {
                Text(session.host.name)
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(Pal.text)
                Text("\(cfg.user)@\(cfg.host):\(cfg.port)")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Pal.subtext)
            }

            Text(statusText)
                .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Pal.fill(0.05), in: Capsule())
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.base.opacity(0.92))
    }

    private var statusIcon: String {
        switch session.phase {
        case .failed: return "exclamationmark.triangle"
        case .disconnected: return "bolt.horizontal.circle"
        default: return "display"
        }
    }

    private var statusText: String {
        switch session.phase {
        case .pending, .connecting: return "正在连接远程桌面…"
        case .connected: return "已连接，等待画面…"
        case .failed(let m): return "连接失败：\(m)"
        case .disconnected: return "连接已断开"
        }
    }
}
