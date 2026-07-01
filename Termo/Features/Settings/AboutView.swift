import AppKit
import SwiftUI

/// 「关于」内容卡片——设置页的「关于」与菜单打开的独立「关于」窗口共用同一份。
struct AboutContent: View {
    var showUpdateStatus: Bool = true   // 独立「关于」弹窗里置 false：不显示「上次检查」等状态文字，更精简
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 28))
                    .foregroundStyle(Pal.mauve)
                    .frame(width: 52, height: 52)
                    .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Termo").font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.text)
                    Text(AppInfo.versionLine)
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
                Spacer()
                UpdateInlineControls(showStatus: showUpdateStatus)   // 软件更新：自动检查开关 + 检查更新按钮，置于头部右侧
            }
            Divider().background(Pal.fill(0.06)).padding(.vertical, 6)
            linkLine("GitHub", "github.com/icloudza/termo", url: "https://github.com/icloudza/termo")
            infoLine(String(localized: "终端引擎"), value: "SwiftTerm 1.13")
            infoLine(String(localized: "渲染"), value: "CoreText / AppKit")
            infoLine(String(localized: "平台"), value: "macOS 14+")
            infoLine(String(localized: "架构"), value: "Apple Silicon")
            privacyLine
        }
        .padding(20)
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
    }

    private var privacyLine: some View {
        Button { showPrivacy = true } label: {
            HStack {
                Text(String(localized: "隐私政策")).font(.system(size: 12)).foregroundStyle(Pal.overlay)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.subtext)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func infoLine(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.overlay)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.subtext)
        }
    }

    @ViewBuilder
    private func linkLine(_ label: String, _ text: String, url: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.overlay)
            Spacer()
            if let u = URL(string: url) {
                Link(text, destination: u)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x89b4fa))
                    .pointerCursor()
            } else {
                Text(text).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            }
        }
    }
}

/// 独立「关于」窗口的根视图（菜单「关于 termo」打开）。
struct AboutWindow: View {
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        AboutContent(showUpdateStatus: false)   // 独立弹窗不显示「上次检查」状态文字
            .padding(24)
            .frame(width: 460)
            .background(Pal.solidBase)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
