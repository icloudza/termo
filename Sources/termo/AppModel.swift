import AppKit
import Combine
import SwiftTerm
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var section: Section = .hosts
    @Published var query: String = ""
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: Int? = nil
    @Published var sidebarWidth: CGFloat = 224
    @Published var settingsTab: SettingsTab = .general
    @Published var showSettings = false
    @Published var showAddHost = false

    @Published var hosts: [Host] = Host.mock

    /// 现有分组（保持出现顺序，去重）
    var groupNames: [String] {
        var seen: [String] = []
        for h in hosts where !seen.contains(h.group) { seen.append(h.group) }
        return seen
    }

    func addHost(from draft: HostDraft) {
        let conn = draft.buildConnection()
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let addr = "\(conn.user)@\(conn.host)"
        let id = "host-\(name)-\(hosts.count)-\(Int(Date().timeIntervalSince1970))"
        let newHost = Host(
            id: id,
            name: name,
            addr: addr,
            group: draft.resolvedGroup,
            status: .unknown,
            os: "未知",
            port: conn.port,
            ssh: conn
        )
        hosts.append(newHost)
    }

    private var terminals: [Int: LocalProcessTerminalView] = [:]
    private var nextTabId = 1
    private var terminalCount = 0
    private var themeCancellable: AnyCancellable?

    private var settingsCancellable: AnyCancellable?

    init() {
        // 主题切换时转发，让所有观察 model 的视图重绘并读取新的 Pal 配色
        themeCancellable = ThemeManager.shared.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            // 主题变化后刷新所有终端配色
            DispatchQueue.main.async { self?.applyThemeToTerminals() }
        }
        // 窗口透明度/效果变化时也刷新视图与终端背景
        settingsCancellable = AppSettings.shared.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.applyThemeToTerminals() }
        }
    }

    var activeHostId: String? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })?.hostId
    }

    func host(_ id: String?) -> Host? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    // ---------- 终端 ----------
    func terminalView(for tabId: Int) -> LocalProcessTerminalView {
        if let tv = terminals[tabId] { return tv }
        let conn = tabs.first(where: { $0.id == tabId })?.hostId
            .flatMap { hid in hosts.first(where: { $0.id == hid })?.ssh }
        let tv = makeTerminal(ssh: conn)
        terminals[tabId] = tv
        return tv
    }

    private static let terminalFont: NSFont = {
        let size: CGFloat = 14
        let preferred = [
            "JetBrainsMono Nerd Font",
            "MesloLGM Nerd Font",
            "MesloLGS Nerd Font",
            "Hack Nerd Font",
            "FiraCode Nerd Font",
            "FiraCode Nerd Font Mono",
        ]
        for name in preferred {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }()

    private static func c(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    // VSCode 终端默认 ANSI 调色板
    private static let darkPalette: [SwiftTerm.Color] = [
        c(0x00, 0x00, 0x00), c(0xcd, 0x31, 0x31), c(0x0d, 0xbc, 0x79), c(0xe5, 0xe5, 0x10),
        c(0x24, 0x72, 0xc8), c(0xbc, 0x3f, 0xbc), c(0x11, 0xa8, 0xcd), c(0xe5, 0xe5, 0xe5),
        c(0x66, 0x66, 0x66), c(0xf1, 0x4c, 0x4c), c(0x23, 0xd1, 0x8b), c(0xf5, 0xf5, 0x43),
        c(0x3b, 0x8e, 0xea), c(0xd6, 0x70, 0xd6), c(0x29, 0xb8, 0xdb), c(0xe5, 0xe5, 0xe5),
    ]

    private static let lightPalette: [SwiftTerm.Color] = [
        c(0x00, 0x00, 0x00), c(0xcd, 0x31, 0x31), c(0x00, 0xbc, 0x00), c(0x94, 0x95, 0x00),
        c(0x00, 0x06, 0xc8), c(0xbc, 0x05, 0xbc), c(0x00, 0x98, 0xa8), c(0x55, 0x55, 0x55),
        c(0x66, 0x66, 0x66), c(0xcd, 0x31, 0x31), c(0x14, 0xce, 0x14), c(0xb5, 0xba, 0x00),
        c(0x04, 0x51, 0xa5), c(0xbc, 0x05, 0xbc), c(0x00, 0x98, 0xa8), c(0xa5, 0xa5, 0xa5),
    ]

    private func applyTheme(to tv: LocalProcessTerminalView) {
        let t = ThemeManager.shared.colors
        let alpha = AppSettings.shared.surfaceAlpha
        let transparent = alpha < 0.999
        tv.installColors(ThemeManager.shared.isDark ? Self.darkPalette : Self.lightPalette)
        tv.nativeBackgroundColor = NSColor(hex: t.termBg).withAlphaComponent(alpha)
        tv.nativeForegroundColor = NSColor(hex: t.termFg)
        tv.selectedTextBackgroundColor = NSColor(hex: t.termSelection)
        tv.caretColor = NSColor(hex: t.termCaret)
        tv.caretTextColor = NSColor(hex: t.termBg)
        // 透明时让终端视图非不透明，使窗口模糊/桌面透出
        tv.wantsLayer = true
        tv.layer?.isOpaque = !transparent
        tv.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func applyThemeToTerminals() {
        for tv in terminals.values {
            applyTheme(to: tv)
            // 强制全屏重绘，清掉旧的不透明像素
            tv.getTerminal().updateFullScreen()
            tv.setNeedsDisplay(tv.bounds)
        }
    }

    private func makeTerminal(ssh: SSHConnection? = nil) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        tv.font = Self.terminalFont
        applyTheme(to: tv)

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
        if !lang.uppercased().contains("UTF-8") {
            env.append("LANG=en_US.UTF-8")
        }

        if let ssh {
            // 真实 SSH 连接
            let args = ssh.sshArguments()
            if ssh.usesPassword, let sshpass = Self.sshpassPath() {
                // 用 sshpass -e，密码经环境变量传入（不暴露在进程参数里）
                env.append("SSHPASS=\(ssh.password)")
                tv.startProcess(executable: sshpass, args: ["-e", "ssh"] + args, environment: env)
            } else {
                tv.startProcess(executable: "/usr/bin/ssh", args: args, environment: env)
            }
            // 连接后执行初始命令 / 切换默认路径（best-effort）
            scheduleInitialCommands(tv, ssh: ssh)
        } else {
            let shell = AppSettings.shared.resolvedShell
            tv.startProcess(executable: shell, args: ["-l"], environment: env)
        }
        return tv
    }

    // ---------- 启动行为 ----------
    private var didApplyStartup = false
    func applyStartupIfNeeded() {
        guard !didApplyStartup else { return }
        didApplyStartup = true
        switch AppSettings.shared.startupBehavior {
        case .terminal:
            openLocalTerminal()
        case .welcome, .restore:
            // 欢迎页为默认（标签为空时即显示）；会话恢复待持久化功能后实现
            break
        }
    }

    static func sshpassPath() -> String? {
        for p in ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass", "/usr/bin/sshpass"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    private func scheduleInitialCommands(_ tv: LocalProcessTerminalView, ssh: SSHConnection) {
        let path = ssh.defaultPath.trimmingCharacters(in: .whitespaces)
        let cmd = ssh.initialCommand.trimmingCharacters(in: .whitespaces)
        guard (!path.isEmpty && path != "~") || !cmd.isEmpty else { return }
        var line = ""
        if !path.isEmpty && path != "~" { line += "cd \(path)" }
        if !cmd.isEmpty { line += (line.isEmpty ? "" : " && ") + cmd }
        line += "\n"
        // 等待 SSH 登录完成后再发送
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak tv] in
            guard let tv else { return }
            tv.send(txt: line)
        }
    }

    // ---------- 标签操作 ----------
    func openLocalTerminal() {
        terminalCount += 1
        addTab(.terminal, title: "本地终端 \(terminalCount)", hostId: nil)
    }

    func openHost(_ host: Host) {
        if let existing = tabs.first(where: { $0.kind == .overview && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        addTab(.overview, title: host.name, hostId: host.id)
    }

    func openHostTerminal(_ host: Host) {
        addTab(.terminal, title: host.name, hostId: host.id)
    }

    private func addTab(_ kind: TabKind, title: String, hostId: String?) {
        let id = nextTabId
        nextTabId += 1
        tabs.append(TabItem(id: id, kind: kind, title: title, hostId: hostId))
        activeTabId = id
    }

    func selectTab(_ id: Int) {
        activeTabId = id
    }

    @Published var pendingCloseTabId: Int? = nil

    func closeTab(_ id: Int) {
        if shouldConfirmClose(id) {
            pendingCloseTabId = id
        } else {
            performCloseTab(id)
        }
    }

    func confirmPendingClose() {
        if let id = pendingCloseTabId {
            performCloseTab(id)
        }
        pendingCloseTabId = nil
    }

    func cancelPendingClose() {
        pendingCloseTabId = nil
    }

    private func performCloseTab(_ id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        terminals.removeValue(forKey: id)
        if activeTabId == id {
            activeTabId = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
    }

    /// 该终端是否有正在运行的活跃进程，需要确认后再关闭。
    private func shouldConfirmClose(_ id: Int) -> Bool {
        guard AppSettings.shared.closeConfirm else { return false }
        guard let tab = tabs.first(where: { $0.id == id }), tab.kind == .terminal else { return false }
        guard let tv = terminals[id] else { return false }

        // SSH 会话：关闭即断开远程连接，始终确认
        if let hid = tab.hostId, hosts.first(where: { $0.id == hid })?.ssh != nil {
            return true
        }
        // 本地终端：比较 PTY 前台进程组与 shell 自身，不同则说明有前台任务在跑
        let fd = tv.process.childfd
        let shellPid = tv.process.shellPid
        guard fd >= 0, shellPid > 0 else { return false }
        let fg = tcgetpgrp(fd)
        return fg > 0 && fg != shellPid
    }

    /// 待关闭标签的标题（用于确认弹窗文案）。
    var pendingCloseTitle: String {
        guard let id = pendingCloseTabId else { return "" }
        return tabs.first(where: { $0.id == id })?.title ?? ""
    }
}
