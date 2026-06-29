import SwiftUI

/// RDP 远程桌面标签页。
///
/// 脚手架阶段：展示目标主机与会话参数的占位面板。后续阶段这里会被替换为
/// 承载 FreeRDP 帧缓冲的 `RDPSurfaceView`（自绘 NSView + 键鼠转发）。
struct RDPSessionView: View {
    @ObservedObject var session: RDPSession
    @ObservedObject private var theme = ThemeManager.shared

    private var cfg: RDPConnection { session.config }

    var body: some View {
        ZStack {
            Pal.base
            VStack(spacing: 16) {
                Image(systemName: "display")
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

                Text("远程桌面渲染内核（FreeRDP）接入中 · 阶段 C")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Pal.fill(0.05), in: Capsule())

                HStack(spacing: 22) {
                    infoItem("分辨率", "\(cfg.width)×\(cfg.height)")
                    infoItem("色深", "\(cfg.colorDepth) 位")
                    infoItem("安全", cfg.security.label)
                    if !cfg.domain.isEmpty { infoItem("域", cfg.domain) }
                }
                .padding(.top, 6)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoItem(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
        }
    }
}
