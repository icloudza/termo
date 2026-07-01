import SwiftUI

/// 软件更新内联控件：复用于「关于窗口」与「设置 ▸ 关于」。渠道自适应——
/// Developer ID 走应用内 Sparkle（自动检查开关 + 立即检查）；MAS 引导到 App Store。
struct UpdateInlineControls: View {
    var showStatus: Bool = true   // 状态文字（如「上次检查：…」）；独立「关于」弹窗里置 false 以更精简
    @ObservedObject private var u = UpdateController.shared
    @ObservedObject private var theme = ThemeManager.shared

    // 紧凑右对齐，置于「关于」头部 Termo 右侧（不再是底部整块；故去掉「软件更新」小标题）。
    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if u.supportsInApp {
                HStack(spacing: 6) {
                    Text("自动检查更新").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    ThemedToggle(isOn: $u.automaticChecks)
                        .scaleEffect(0.78).frame(width: 30, height: 17)
                }
            }
            HStack(spacing: 6) {
                if showStatus {
                    Text(statusText).font(.system(size: 10)).foregroundStyle(Pal.overlay).lineLimit(1)
                }
                trailingControl
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if u.supportsInApp {
            switch u.phase {
            case .checking, .downloading, .extracting, .installing:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    miniButton(String(localized: "查看")) { UpdateWindowPresenter.shared.present() }
                }
            case .found, .readyToInstall:
                miniButton(String(localized: "查看更新"), primary: true) { UpdateWindowPresenter.shared.present() }
            default:
                miniButton(String(localized: "检查更新")) { u.checkForUpdates(surfaceTransient: false) }
            }
        } else {
            miniButton(String(localized: "在 App Store 中检查")) { u.checkForUpdates() }
        }
    }

    /// 头部右侧用的小号按钮（比通用 Primary/SecondaryButton 更紧凑）。
    private func miniButton(_ title: String, primary: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11, weight: primary ? .medium : .regular))
                .foregroundStyle(primary ? .white : Pal.subtext)
                .lineLimit(1).fixedSize()   // 按钮文字始终单行贴合，不换行变胖
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(primary ? Pal.mauve : Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private var statusText: String {
        if !u.supportsInApp { return String(localized: "通过 App Store 接收更新") }
        switch u.phase {
        case .checking:      return String(localized: "正在检查更新…")
        case .found:         return String(localized: "发现新版本") + (u.info.map { " \($0.displayVersion)" } ?? "")
        case .downloading, .extracting: return String(localized: "正在更新…")
        case .readyToInstall: return String(localized: "更新已就绪，待重启安装")
        case .installing:    return String(localized: "正在安装…")
        case .upToDate:      return String(localized: "已是最新版本")
        case .error:         return String(localized: "上次检查失败")
        case .idle:
            guard let d = u.lastCheckDate else { return String(localized: "尚未检查更新") }
            if Date().timeIntervalSince(d) < 60 { return String(localized: "上次检查：刚刚") }   // 避免「0秒后」这类四舍五入错向
            return String(localized: "上次检查：") + Self.relative.localizedString(for: d, relativeTo: Date())
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.unitsStyle = .short
        return f
    }()
}
