import AppKit
import SwiftUI

/// 应用内隐私政策。文案随界面语言切换（中/英双语字面量，避免把大段法律文本拆进 xcstrings）。
/// 事实基线：不收集任何个人信息、无分析/追踪；网络连接仅发生在用户与其自有服务器之间；
/// 未来若加 iCloud 同步也只经用户自己的 iCloud，绝不回传开发者。
struct PrivacyPolicyView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    private var isEnglish: Bool {
        (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("en")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(effectiveDate)
                        .font(.system(size: 11))
                        .foregroundStyle(Pal.overlay)
                    ForEach(sections.indices, id: \.self) { i in
                        section(sections[i].0, sections[i].1)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 620)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack {
            Text(isEnglish ? "Privacy Policy" : "隐私政策")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Pal.text)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Pal.text)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(Pal.subtext)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectiveDate: String {
        isEnglish ? "Effective date: July 1, 2026" : "生效日期：2026 年 7 月 1 日"
    }

    private var sections: [(String, String)] {
        isEnglish ? Self.english : Self.chinese
    }

    private static let chinese: [(String, String)] = [
        ("概述",
         "Termo 不收集、不存储、不上传你的任何个人信息。App 没有账号体系，没有分析、埋点或追踪，也不含任何以收集数据为目的的第三方 SDK 或广告。"),
        ("你的数据存在哪里",
         "你添加的主机、会话、代码片段等配置，全部保存在你自己的 Mac 本地。密码与密钥口令存放于系统钥匙串（Keychain），从不明文落盘，也不会离开你的设备。"),
        ("网络连接",
         "Termo 发起的网络连接，只有你自己主动建立的那些：SSH、SFTP、Windows 远程桌面、端口转发——它们直接发生在你的 Mac 与你所配置的服务器之间。这些数据不经过开发者，开发者也无法看到任何内容。"),
        ("软件更新",
         "非 App Store 版本会定期向更新服务器检查是否有新版本，此过程不发送任何个人信息。通过 App Store 安装的版本则由 App Store 负责更新。"),
        ("iCloud 同步（未来）",
         "未来版本可能提供可选的 iCloud 同步，用于在你自己的多台设备之间同步配置。该功能使用你自己的 Apple iCloud 账户，数据仅保存在你的私有 iCloud 中，绝不会发送给开发者或任何第三方服务器，更不会接入任何私有网络。"),
        ("儿童隐私",
         "Termo 不面向儿童，也不会有意收集任何人的个人信息。"),
        ("政策变更",
         "若本政策有更新，会随新版本在应用内一并提供，并更新上方的生效日期。"),
        ("联系我们",
         "如对隐私有任何疑问，可在项目仓库提交 issue：github.com/icloudza/termo"),
    ]

    private static let english: [(String, String)] = [
        ("Overview",
         "Termo does not collect, store, or upload any of your personal information. The app has no account system, no analytics, no tracking, and contains no third-party SDKs or ads that gather data."),
        ("Where your data lives",
         "The hosts, sessions, snippets, and other configuration you create are stored locally on your own Mac. Passwords and key passphrases are kept in the system Keychain — never written to disk in plaintext, and never leaving your device."),
        ("Network connections",
         "The only network connections Termo makes are the ones you initiate yourself: SSH, SFTP, Windows Remote Desktop, and port forwarding. These happen directly between your Mac and the servers you configure. That traffic never passes through the developer, and the developer cannot see any of it."),
        ("Software updates",
         "The non-App-Store build periodically checks an update server for a new version; this transmits no personal information. Builds installed from the App Store are updated by the App Store."),
        ("iCloud sync (future)",
         "A future version may offer optional iCloud sync to keep your configuration in sync across your own devices. It uses your own Apple iCloud account; data is stored only in your private iCloud and is never sent to the developer or any third-party server, nor to any private network."),
        ("Children's privacy",
         "Termo is not directed at children and does not knowingly collect personal information from anyone."),
        ("Changes to this policy",
         "If this policy changes, the updated version ships inside the app with a revised effective date shown above."),
        ("Contact",
         "For any privacy questions, open an issue in the project repository: github.com/icloudza/termo"),
    ]
}
