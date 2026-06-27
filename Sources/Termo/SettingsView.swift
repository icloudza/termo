import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Pal.fill(0.06))
            content
        }
        .frame(width: 720, height: 480)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
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
                Text(tab.rawValue)
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
            sectionHeader("通用")

            settingRow("外观模式", description: "切换深色、浅色或跟随系统") {
                SegmentedControl(
                    options: AppearanceMode.allCases.map { ($0, $0.rawValue) },
                    selection: $theme.mode
                )
                .frame(width: 240)
            }

            settingRow("启动行为", description: "应用启动时的默认操作") {
                ThemedDropdown(
                    options: [(StartupBehavior.welcome, "显示欢迎页"), (.terminal, "打开新终端"), (.restore, "恢复上次会话")],
                    selection: $settings.startupBehavior
                )
                .frame(width: 160)
            }

            settingRow("关闭窗口时隐藏到菜单栏", description: "关闭主窗口不退出，后台任务（如端口转发）继续运行；从菜单栏图标恢复") {
                ThemedToggle(isOn: $settings.closeToTray)
            }

            settingRow("删除主机前确认", description: "删除主机时弹出确认弹窗，避免误删") {
                ThemedToggle(isOn: $settings.confirmHostDelete)
            }
        }
    }

    // MARK: - 传输

    private var transferSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("传输")

            settingRow("下载时询问位置", description: "每次下载都弹出选择保存位置") {
                ThemedToggle(isOn: $settings.downloadAskEachTime)
            }

            if !settings.downloadAskEachTime {
                settingRow("默认下载目录", description: "下载的文件保存到此处") {
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

            settingRow("并发传输数", description: "同时进行的上传/下载数量（共用一个池），超出自动排队") {
                ThemedDropdown(
                    options: [(1, "1 个"), (2, "2 个"), (3, "3 个"), (4, "4 个"), (5, "5 个")],
                    selection: $settings.maxConcurrentTransfers
                )
                .frame(width: 120)
            }
        }
    }

    // MARK: - 监控

    private var monitorSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("监控")

            settingRow("资源告警", description: "主机 CPU、内存或磁盘持续高占用时发送系统通知") {
                ThemedToggle(isOn: $settings.resourceAlerts)
            }

            settingRow("隐藏监控提示", description: "不再显示监控面板顶部的数据采集说明") {
                ThemedToggle(isOn: $settings.monitorNoticeHidden)
            }
        }
    }

    private func chooseDownloadDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = settings.resolvedDownloadDir
        if panel.runModal() == .OK, let url = panel.url { settings.downloadDir = url.path }
    }

    // MARK: - 终端

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("终端")

            settingRow("默认 Shell", description: "新终端使用的 Shell 程序") {
                ThemedDropdown(
                    options: [(DefaultShell.auto, "自动检测"), (.zsh, "/bin/zsh"), (.bash, "/bin/bash")],
                    selection: $settings.defaultShell
                )
                .frame(width: 160)
            }

            settingRow("关闭确认", description: "关闭有活跃进程的终端时提示确认") {
                ThemedToggle(isOn: $settings.closeConfirm)
            }

            settingRow("字体", description: "终端显示使用的字体") {
                ThemedDropdown(
                    options: [
                        ("", "自动 (推荐)"),
                        ("SF Mono", "SF Mono"), ("Menlo", "Menlo"), ("Monaco", "Monaco"),
                        ("JetBrainsMono Nerd Font", "JetBrains Mono"),
                        ("FiraCode Nerd Font", "Fira Code"),
                        ("MesloLGM Nerd Font", "Meslo LGM"),
                    ],
                    selection: $settings.termFont
                )
                .frame(width: 220)
            }

            settingRow("字号", description: "终端字体大小") {
                ThemedStepper(value: $settings.termFontSize, range: 10...24, suffix: " pt")
            }

            settingRow("光标样式", description: "终端光标的形状") {
                SegmentedControl(
                    options: [("block", "方块"), ("bar", "竖线"), ("underline", "下划线")],
                    selection: $settings.termCursorStyle
                )
                .frame(width: 220)
            }

            settingRow("光标闪烁", description: "光标是否闪烁") {
                ThemedToggle(isOn: $settings.termCursorBlink)
            }

            settingRow("滚动缓冲区", description: "终端保留的最大行数") {
                ThemedDropdown(
                    options: [(500, "500 行"), (1000, "1,000 行"), (5000, "5,000 行"), (10000, "10,000 行"), (50000, "50,000 行")],
                    selection: $settings.termScrollback
                )
                .frame(width: 140)
            }
        }
    }

    // MARK: - 快捷键

    private var keysSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("快捷键")

            shortcutRow("新建终端", shortcut: "⌘ T")
            shortcutRow("关闭标签", shortcut: "⌘ W")
            shortcutRow("复制", shortcut: "⌘ C")
            shortcutRow("粘贴", shortcut: "⌘ V")
            shortcutRow("清屏", shortcut: "⌘ K")
            shortcutRow("搜索", shortcut: "⌘ F")
            shortcutRow("切换侧栏", shortcut: "⌘ B")
            shortcutRow("下一个标签", shortcut: "⌃ Tab")
            shortcutRow("上一个标签", shortcut: "⌃ ⇧ Tab")
            shortcutRow("放大字体", shortcut: "⌘ +")
            shortcutRow("缩小字体", shortcut: "⌘ -")
        }
    }

    // MARK: - 关于

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("关于")
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
