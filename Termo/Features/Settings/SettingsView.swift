import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var certStore = RDPCertTrustStore.shared
    @State private var showLanguageRestart = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Pal.fill(0.06))
            content
        }
        .frame(width: 720, height: 480)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onChange(of: settings.appLanguage) { showLanguageRestart = true }
        .overlay {
            if showLanguageRestart {
                ConfirmDialog(
                    title: "重启以应用语言",
                    message: "语言更改需重启 Termo 后生效。",
                    confirmTitle: "立即重启",
                    cancelTitle: "稍后",
                    onConfirm: { showLanguageRestart = false; Self.relaunch() },
                    onCancel: { showLanguageRestart = false })
            }
        }
    }

    /// 干净重启：先关所有模态 sheet（SwiftUI 的 .sheet 会拦截 NSApp.terminate，不先关就会
    /// 「新实例已起、旧实例退不掉」双开），留一拍让其关闭，再启动新实例并退出旧进程。
    static func relaunch() {
        AppModel.shared.dismissAllSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - 左侧导航

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    navItem(tab)
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(width: 176)
        .frame(maxHeight: .infinity)
        .background(Pal.solidMantle)
    }

    private func navItem(_ tab: SettingsTab) -> some View {
        let selected = model.settingsTab == tab
        return Button {
            model.settingsTab = tab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Pal.mauve : Pal.overlay)
                    .frame(width: 18)
                Text(tab.label)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Pal.text : Pal.subtext)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                selected ? Pal.mauve.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - 右侧内容

    private var content: some View {
        VStack(spacing: 0) {
            // 顶部关闭栏
            HStack {
                Spacer()
                Button {
                    model.showSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 26, height: 26)
                        .background(Pal.fill(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.settingsTab {
                    case .general: generalSettings
                    case .terminal: terminalSettings
                    case .transfer: transferSettings
                    case .monitor: monitorSettings
                    case .security: securitySettings
                    case .keys: keysSettings
                    case .about: aboutSettings
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.solidBase)
    }

    // MARK: - 通用

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "通用"))

            settingRow(String(localized: "外观模式"), description: String(localized: "切换深色、浅色或跟随系统")) {
                SegmentedControl(
                    options: AppearanceMode.allCases.map { (value: $0, verbatim: $0.label) },
                    selection: $theme.mode
                )
                .frame(width: 240)
            }

            settingRow(String(localized: "语言"), description: String(localized: "界面语言，更改后需重启 Termo 生效")) {
                ThemedDropdown(
                    options: AppLanguage.allCases.map { (value: $0, verbatim: $0.label) },
                    selection: $settings.appLanguage
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "启动行为"), description: String(localized: "应用启动时的默认操作")) {
                ThemedDropdown(
                    options: [(StartupBehavior.welcome, String(localized: "显示欢迎页")), (.terminal, String(localized: "打开新终端"))],
                    selection: $settings.startupBehavior
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "关闭窗口时隐藏到菜单栏"), description: String(localized: "关闭主窗口不退出，后台任务（如端口转发）继续运行；从菜单栏图标恢复")) {
                ThemedToggle(isOn: $settings.closeToTray)
            }

            settingRow(String(localized: "删除主机前确认"), description: String(localized: "删除主机时弹出确认弹窗，避免误删")) {
                ThemedToggle(isOn: $settings.confirmHostDelete)
            }

            settingRow(String(localized: "远程桌面打开方式"), description: String(localized: "RDP 连接成功后内嵌为标签还是在新窗口打开；「每次询问」会弹出选择且可记住")) {
                ThemedDropdown(
                    options: RDPOpenMode.allCases.map { ($0, $0.label) },
                    selection: $settings.rdpOpenMode
                )
                .frame(width: 160)
            }

            if settings.rdpOpenMode == .window {
                settingRow(String(localized: "新窗口行为"), description: String(localized: "「新窗口」打开时，新的远程桌面窗口是否默认进入全屏")) {
                    ThemedDropdown(
                        options: [(true, String(localized: "默认全屏")), (false, String(localized: "不全屏"))],
                        selection: $settings.rdpWindowFullscreen
                    )
                    .frame(width: 160)
                }
            }

            settingRow(String(localized: "远程桌面剪贴板同步"), description: String(localized: "RDP 连接的本地与远端剪贴板双向同步纯文本（复制粘贴互通）；关闭则两端剪贴板互不影响")) {
                ThemedToggle(isOn: $settings.rdpClipboardSync)
            }
        }
    }

    // MARK: - 传输

    private var transferSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "传输"))

            settingRow(String(localized: "下载时询问位置"), description: String(localized: "每次下载都弹出选择保存位置")) {
                ThemedToggle(isOn: $settings.downloadAskEachTime)
            }

            if !settings.downloadAskEachTime {
                settingRow(String(localized: "默认下载目录"), description: String(localized: "下载的文件保存到此处")) {
                    HStack(spacing: 8) {
                        Text(settings.resolvedDownloadDir.path)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                            .tooltip(settings.resolvedDownloadDir.path)
                        SecondaryButton(title: "选择…", action: chooseDownloadDir)
                    }
                }
            }

            settingRow(String(localized: "下载时显示弹窗"), description: String(localized: "关闭后下载不弹进度窗口，仅以弧线动画飞入左下角后台任务；进度仍可在后台任务中查看")) {
                ThemedToggle(isOn: $settings.showDownloadDialog)
            }

            settingRow(String(localized: "并发传输数"), description: String(localized: "同时进行的上传/下载数量（共用一个池），超出自动排队")) {
                ThemedDropdown(
                    options: [(1, String(localized: "1 个")), (2, String(localized: "2 个")), (3, String(localized: "3 个")), (4, String(localized: "4 个")), (5, String(localized: "5 个"))],
                    selection: $settings.maxConcurrentTransfers
                )
                .frame(width: 120)
            }

            settingRow(String(localized: "暂停时让出名额"), description: String(localized: "开启：暂停任务后空出的名额让排队任务先跑；关闭：暂停任务仍占名额，保持原执行顺序")) {
                ThemedToggle(isOn: $settings.pausedReleasesSlot)
            }
        }
    }

    // MARK: - 监控

    private var monitorSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "监控"))

            settingRow(String(localized: "资源告警"), description: String(localized: "主机 CPU、内存或磁盘持续高占用时发送系统通知")) {
                ThemedToggle(isOn: $settings.resourceAlerts)
            }

            settingRow(String(localized: "隐藏监控提示"), description: String(localized: "不再显示监控面板顶部的数据采集说明")) {
                ThemedToggle(isOn: $settings.monitorNoticeHidden)
            }
        }
    }

    // MARK: - 安全

    private var securitySettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "安全"))

            VStack(alignment: .leading, spacing: 10) {
                Text("已信任的远程桌面证书")
                    .font(.system(size: 13)).foregroundStyle(Pal.text)
                Text("连接 RDP 主机时勾选「始终信任此电脑」后记录于此。撤销后该主机下次连接会重新询问。")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)

                if certStore.entries.isEmpty {
                    Text("暂无已信任的证书")
                        .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 0) {
                        ForEach(certStore.entries) { cert in
                            trustedCertRow(cert)
                            if cert.id != certStore.entries.last?.id {
                                Divider().overlay(Pal.fill(0.06))
                            }
                        }
                    }
                    .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.fill(0.06), lineWidth: 1))
                }
            }
        }
    }

    private func trustedCertRow(_ cert: RDPTrustedCert) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 14)).foregroundStyle(Pal.mauve)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(cert.host):\(cert.port)")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Pal.text)
                Text(cert.fingerprint.isEmpty ? String(localized: "（无指纹）") : cert.fingerprint)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
                    .tooltip(cert.fingerprint)
            }
            Spacer()
            SecondaryButton(title: "撤销") { certStore.revoke(cert.id) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func chooseDownloadDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "选择")
        panel.directoryURL = settings.resolvedDownloadDir
        if panel.runModal() == .OK, let url = panel.url { settings.downloadDir = url.path }
    }

    // MARK: - 终端

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "终端"))

            settingRow(String(localized: "默认 Shell"), description: String(localized: "新终端使用的 Shell 程序")) {
                ThemedDropdown(
                    options: [(DefaultShell.auto, String(localized: "自动检测")), (.zsh, "/bin/zsh"), (.bash, "/bin/bash")],
                    selection: $settings.defaultShell
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "关闭确认"), description: String(localized: "关闭有活跃进程的终端时提示确认")) {
                ThemedToggle(isOn: $settings.closeConfirm)
            }

            settingRow(String(localized: "代码片段运行方式"), description: String(localized: "点击片段时的默认行为；「每次询问」会弹出「插入/运行」选择且可记住")) {
                ThemedDropdown(
                    options: SnippetAction.allCases.map { ($0, $0.label) },
                    selection: $settings.snippetAction
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "字体"), description: String(localized: "终端显示使用的字体")) {
                ThemedDropdown(
                    options: [
                        ("", String(localized: "自动 (推荐)")),
                        ("SF Mono", "SF Mono"), ("Menlo", "Menlo"), ("Monaco", "Monaco"),
                        ("JetBrainsMono Nerd Font", "JetBrains Mono"),
                        ("FiraCode Nerd Font", "Fira Code"),
                        ("MesloLGM Nerd Font", "Meslo LGM"),
                    ],
                    selection: $settings.termFont
                )
                .frame(width: 220)
            }

            settingRow(String(localized: "字号"), description: String(localized: "终端字体大小")) {
                ThemedStepper(value: $settings.termFontSize, range: 10...24, suffix: " pt")
            }

            settingRow(String(localized: "光标样式"), description: String(localized: "终端光标的形状")) {
                SegmentedControl(
                    options: [(value: "block", label: "方块"), (value: "bar", label: "竖线"), (value: "underline", label: "下划线")],
                    selection: $settings.termCursorStyle
                )
                .frame(width: 220)
            }

            settingRow(String(localized: "光标闪烁"), description: String(localized: "光标是否闪烁")) {
                ThemedToggle(isOn: $settings.termCursorBlink)
            }

            settingRow(String(localized: "滚动缓冲区"), description: String(localized: "终端保留的最大行数")) {
                ThemedDropdown(
                    options: [(500, String(localized: "500 行")), (1000, String(localized: "1,000 行")), (5000, String(localized: "5,000 行")), (10000, String(localized: "10,000 行")), (50000, String(localized: "50,000 行"))],
                    selection: $settings.termScrollback
                )
                .frame(width: 140)
            }
        }
    }

    // MARK: - 快捷键

    private var keysSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "快捷键"))

            shortcutRow(String(localized: "新建终端"), shortcut: "⌘ T")
            shortcutRow(String(localized: "关闭标签"), shortcut: "⌘ W")
            shortcutRow(String(localized: "复制"), shortcut: "⌘ C")
            shortcutRow(String(localized: "粘贴"), shortcut: "⌘ V")
            shortcutRow(String(localized: "清屏"), shortcut: "⌘ K")
            shortcutRow(String(localized: "搜索"), shortcut: "⌘ F")
            shortcutRow(String(localized: "切换侧栏"), shortcut: "⌘ B")
            shortcutRow(String(localized: "下一个标签"), shortcut: "⌃ Tab")
            shortcutRow(String(localized: "上一个标签"), shortcut: "⌃ ⇧ Tab")
            shortcutRow(String(localized: "放大字体"), shortcut: "⌘ +")
            shortcutRow(String(localized: "缩小字体"), shortcut: "⌘ -")
        }
    }

    // MARK: - 关于

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader(String(localized: "关于"))
            AboutContent()   // 与独立「关于」窗口复用同一份内容
        }
    }

    // MARK: - 组件

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Pal.text)
            .padding(.bottom, 4)
    }

    private func settingRow<C: View>(_ title: String, description: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Pal.text)
                Text(description).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 4)
    }

    private func shortcutRow(_ action: String, shortcut: String) -> some View {
        HStack {
            Text(action).font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            Text(shortcut)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Pal.subtext)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.vertical, 2)
    }
}
