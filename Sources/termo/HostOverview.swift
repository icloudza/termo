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
                    if host.status == .online, let ms = host.latencyMs {
                        Text("\(ms) ms").font(.system(size: 12, design: .monospaced)).foregroundStyle(latencyColor(ms))
                    }
                }
                Text("\(host.addr) · 端口 \(host.port)")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .padding(.top, 6).padding(.bottom, 16)

                specsRow

                HStack(spacing: 10) {
                    action("terminal", "终端", primary: true) { model.openHostTerminal(host) }
                    action("folder", "文件 (SFTP)") { model.openHostFiles(host) }
                    action("arrow.left.arrow.right", "端口转发") {}
                    action("pencil", "编辑") { model.beginEditHost(host) }
                }
                .padding(.bottom, 26)

                if !host.notes.isEmpty {
                    Text("备注").font(.system(size: 12)).foregroundStyle(Pal.overlay).padding(.bottom, 8)
                    Text(host.notes)
                        .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 24)
                }

                Text("最近会话").font(.system(size: 12)).foregroundStyle(Pal.overlay).padding(.bottom, 10)
                let recents = model.recentSessions(for: host.id)
                if recents.isEmpty {
                    Text("暂无会话记录")
                        .font(.system(size: 13)).foregroundStyle(Pal.overlay)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                } else {
                    ForEach(recents) { s in
                        recentRow(s.kind.icon, s.detail, Self.relativeTime(s.timestamp))
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.probeHostIfNeeded(host) }
    }

    @ViewBuilder
    private var specsRow: some View {
        if let s = host.specs, !s.isEmpty {
            HStack(spacing: 24) {
                if !s.os.isEmpty { specItem("系统", s.os) }
                if !s.cores.isEmpty { specItem("核心", "\(s.cores) 核") }
                if !s.memory.isEmpty { specItem("内存", s.memory) }
                if !s.disk.isEmpty { specItem("磁盘", s.disk) }
            }
            .padding(.bottom, 20)
        } else if model.probingHosts.contains(host.id) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在获取系统信息…").font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }
            .padding(.bottom, 20)
        }
    }

    private func specItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
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
                    .frame(height: 24)   // 固定图标高度，消除不同字形导致的卡片高度差
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

    /// 把时间格式化为「12 分钟前 / 1 小时前 / 昨天」等中文相对时间。
    static func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: Date())
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
