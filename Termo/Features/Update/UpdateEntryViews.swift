import SwiftUI

/// 软件更新内联控件：复用于「关于窗口」与「设置 ▸ 关于」。渠道自适应——
/// Developer ID 走应用内 Sparkle（自动检查开关 + 立即检查）；MAS 引导到 App Store。
struct UpdateInlineControls: View {
    @ObservedObject private var u = UpdateController.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("软件更新").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)

            if u.supportsInApp {
                HStack {
                    Text("自动检查更新").font(.system(size: 12)).foregroundStyle(Pal.text)
                    Spacer()
                    ThemedToggle(isOn: $u.automaticChecks)
                }
            }

            HStack(spacing: 10) {
                Text(statusText).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                trailingControl
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if u.supportsInApp {
            switch u.phase {
            case .checking, .downloading, .extracting, .installing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    SecondaryButton(title: "查看", action: { UpdateWindowPresenter.shared.present() })
                }
            case .found, .readyToInstall:
                PrimaryButton(title: "查看更新", action: { UpdateWindowPresenter.shared.present() })
            default:
                SecondaryButton(title: "检查更新", action: { u.checkForUpdates() })
            }
        } else {
            SecondaryButton(title: "在 App Store 中检查", action: { u.checkForUpdates() })
        }
    }

    private var statusText: String {
        if !u.supportsInApp { return "通过 App Store 接收更新" }
        switch u.phase {
        case .checking:      return "正在检查更新…"
        case .found:         return "发现新版本" + (u.info.map { " \($0.displayVersion)" } ?? "")
        case .downloading, .extracting: return "正在更新…"
        case .readyToInstall: return "更新已就绪，待重启安装"
        case .installing:    return "正在安装…"
        case .upToDate:      return "已是最新版本"
        case .error:         return "上次检查失败"
        case .idle:
            guard let d = u.lastCheckDate else { return "尚未检查更新" }
            return "上次检查：" + Self.relative.localizedString(for: d, relativeTo: Date())
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.unitsStyle = .short
        return f
    }()
}
