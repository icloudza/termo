import AppKit
import SwiftUI

/// 「关于」内容卡片——设置页的「关于」与菜单打开的独立「关于」窗口共用同一份。
struct AboutContent: View {
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 28))
                    .foregroundStyle(Pal.mauve)
                    .frame(width: 52, height: 52)
                    .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Termo").font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.text)
                    Text(Self.versionLine)
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
            }
            Divider().background(Pal.fill(0.06)).padding(.vertical, 6)
            linkLine("GitHub", "github.com/icloudza/termo", url: "https://github.com/icloudza/termo")
            infoLine("终端引擎", value: "SwiftTerm 1.13")
            infoLine("渲染", value: "CoreText / AppKit")
            infoLine("平台", value: "macOS 13+")
            infoLine("架构", value: "Apple Silicon")
        }
        .padding(20)
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 版本行：读嵌入 Info.plist 的 CFBundleShortVersionString + CFBundleVersion；
    /// 取不到（嵌入未生效）则回退到「开发版」。以后改版本只动 Info.plist 一处。
    static var versionLine: String {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "版本 0.7.4 (开发版)"
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "版本 \(v) (build \($0))" } ?? "版本 \(v)"
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
        AboutContent()
            .padding(24)
            .frame(width: 420)
            .background(Pal.solidBase)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
