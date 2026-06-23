import SwiftUI

struct HostOverview: View {
    let host: Host
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(host.name).font(.system(size: 20, weight: .medium)).foregroundStyle(Pal.textBright)
                    statusBadge
                }
                Text("\(host.addr) · 端口 22 · \(host.os)")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .padding(.top, 6).padding(.bottom, 20)

                HStack(spacing: 10) {
                    action("terminal", "终端", primary: true) { model.openHostTerminal(host) }
                    action("folder", "文件 (SFTP)") {}
                    action("arrow.left.arrow.right", "端口转发") {}
                    action("pencil", "编辑") {}
                }
                .padding(.bottom, 26)

                Text("最近会话").font(.system(size: 12)).foregroundStyle(Pal.overlay).padding(.bottom, 10)
                recentRow("terminal", "终端会话", "12 分钟前")
                recentRow("arrow.up.circle", "上传 deploy.tar.gz", "1 小时前")
                recentRow("arrow.left.arrow.right", "端口转发 8080 → 80", "昨天")
            }
            .padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusBadge: some View {
        let (label, fg, bg): (String, Color, Color) = {
            switch host.status {
            case .online: return ("在线", Pal.green, Pal.green.opacity(0.15))
            case .offline: return ("离线", Pal.overlay, Pal.overlay.opacity(0.15))
            case .unknown: return ("未知", Pal.yellow, Pal.yellow.opacity(0.15))
            }
        }()
        return Text(label).font(.system(size: 11)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func action(_ symbol: String, _ label: String, primary: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 21))
                    .foregroundStyle(primary ? Pal.mauve : Pal.subtext)
                Text(label).font(.system(size: 12)).foregroundStyle(Pal.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                primary ? Pal.mauve.opacity(0.10) : Pal.fill(0.03),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(primary ? Pal.mauve.opacity(0.25) : Pal.fill(0.07), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ symbol: String, _ text: String, _ time: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Pal.overlay).frame(width: 16)
            Text(text).font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            Text(time).font(.system(size: 12)).foregroundStyle(Pal.overlay)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}
