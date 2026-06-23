import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var cursorStyle = "block"
    @State private var fontName = "jetbrains"
    @State private var fontSize = 14
    @State private var cursorBlink = true
    @State private var scrollback = 10000

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
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.settingsTab {
                    case .general: generalSettings
                    case .appearance: appearanceSettings
                    case .terminal: terminalSettings
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

            settingRow("启动行为", description: "应用启动时的默认操作") {
                ThemedDropdown(
                    options: [(StartupBehavior.welcome, "显示欢迎页"), (.terminal, "打开新终端"), (.restore, "恢复上次会话")],
                    selection: $settings.startupBehavior
                )
                .frame(width: 160)
            }

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
        }
    }

    // MARK: - 外观

    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("外观")

            settingRow("外观模式", description: "切换深色、浅色或跟随系统") {
                SegmentedControl(
                    options: AppearanceMode.allCases.map { ($0, $0.rawValue) },
                    selection: $theme.mode
                )
                .frame(width: 240)
            }
        }
    }

    // MARK: - 终端

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("终端")

            settingRow("字体", description: "终端显示使用的字体") {
                ThemedDropdown(
                    options: [
                        ("jetbrains", "JetBrainsMono Nerd Font"), ("meslo", "MesloLGM Nerd Font"),
                        ("firacode", "Fira Code"), ("sfmono", "SF Mono"), ("menlo", "Menlo"),
                    ],
                    selection: $fontName
                )
                .frame(width: 220)
            }

            settingRow("字号", description: "终端字体大小") {
                ThemedStepper(value: $fontSize, range: 10...24, suffix: " pt")
            }

            settingRow("光标样式", description: "终端光标的形状") {
                SegmentedControl(
                    options: [("block", "方块"), ("bar", "竖线"), ("underline", "下划线")],
                    selection: $cursorStyle
                )
                .frame(width: 220)
            }

            settingRow("光标闪烁", description: "光标是否闪烁") {
                ThemedToggle(isOn: $cursorBlink)
            }

            settingRow("滚动缓冲区", description: "终端保留的最大行数") {
                ThemedDropdown(
                    options: [(1000, "1,000 行"), (5000, "5,000 行"), (10000, "10,000 行"), (50000, "50,000 行")],
                    selection: $scrollback
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

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 28))
                        .foregroundStyle(Pal.mauve)
                        .frame(width: 52, height: 52)
                        .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("termo").font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.text)
                        Text("版本 0.1.0 (开发版)")
                            .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    }
                }
                Divider().background(Pal.fill(0.06)).padding(.vertical, 6)
                infoLine("终端引擎", value: "SwiftTerm 1.13")
                infoLine("渲染", value: "CoreText / AppKit")
                infoLine("平台", value: "macOS 13+")
                infoLine("架构", value: "Apple Silicon")
            }
            .padding(20)
            .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 10))
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

    private func infoLine(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.overlay)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.subtext)
        }
    }
}
