import AppKit
import Combine
import Darwin
import SwiftTerm
import SwiftUI

/// 首次连接待验证的主机指纹（弹窗用）。respond 回传用户选择。
struct PendingHostKey: Identifiable {
    let id = UUID()
    let info: HostKeyInfo
    let respond: (HostKeyDecision) -> Void
}

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
    @Published var editingHost: Host? = nil   // 非 nil 时以编辑模式打开主机表单
    @Published var pendingHostKey: PendingHostKey? = nil   // 首次连接待验证的主机指纹
    @Published var connectingHost: Host? = nil   // 正在连接的主机（展示连接进度弹窗）

    @Published var hosts: [Host] = []
    /// 主机会话历史（终端/上传/端口转发），用于「最近会话」。
    @Published var sessions: [SessionEvent] = []
    /// 正在 SSH 探测系统信息的主机 id。
    @Published var probingHosts: Set<String> = []

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
        let id = "host-\(UUID().uuidString)"
        let newHost = Host(
            id: id,
            name: name,
            addr: addr,
            group: draft.resolvedGroup,
            status: .unknown,
            os: "未知",
            port: conn.port,
            ssh: conn,
            notes: draft.notes.trimmingCharacters(in: .whitespaces)
        )
        hosts.append(newHost)
        HostStore.saveHosts(hosts)
        checkReachability(newHost)
    }

    func beginEditHost(_ host: Host) {
        editingHost = host
    }

    /// 用编辑后的表单覆盖已有主机（保持 id / 状态 / 系统不变）。
    func updateHost(id: String, from draft: HostDraft) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        let conn = draft.buildConnection()
        let old = hosts[idx]
        hosts[idx] = Host(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            addr: "\(conn.user)@\(conn.host)",
            group: draft.resolvedGroup,
            status: old.status,
            os: old.os,
            port: conn.port,
            ssh: conn,
            notes: draft.notes.trimmingCharacters(in: .whitespaces)
        )
        HostStore.saveHosts(hosts)
        checkReachability(hosts[idx])
    }

    func deleteHost(_ id: String) {
        hosts.removeAll { $0.id == id }
        sessions.removeAll { $0.hostId == id }
        HostKeychain.delete(id)
        HostStore.saveHosts(hosts)
        HostStore.saveSessions(sessions)
    }

    // ---------- 会话历史 ----------
    /// 记录一条会话事件并持久化。
    func recordSession(hostId: String, kind: SessionKind, detail: String) {
        sessions.append(SessionEvent(hostId: hostId, kind: kind, detail: detail, timestamp: Date()))
        // 每台主机最多保留 50 条，避免无限增长
        let perHost = Dictionary(grouping: sessions, by: \.hostId)
        var trimmed: [SessionEvent] = []
        for (_, evs) in perHost {
            trimmed += evs.sorted { $0.timestamp > $1.timestamp }.prefix(50)
        }
        sessions = trimmed
        HostStore.saveSessions(sessions)
    }

    /// 某主机最近的会话（倒序，最多 limit 条）。
    func recentSessions(for hostId: String, limit: Int = 6) -> [SessionEvent] {
        sessions
            .filter { $0.hostId == hostId }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // ---------- 系统信息探测 ----------
    /// 远端一次性探测脚本：输出 OS/CORES/MEM/DISK 四行 key=value。
    private static let probeScript =
        ". /etc/os-release 2>/dev/null; " +
        "echo \"OS=${PRETTY_NAME:-$(uname -sr)}\"; " +
        "echo \"CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)\"; " +
        "echo \"MEM=$(free -h 2>/dev/null | awk 'NR==2{print $2}')\"; " +
        "echo \"DISK=$(df -h / 2>/dev/null | awk 'NR==2{print $3\"/\"$2}')\""

    /// 打开主机概览时调用：后台 SSH 跑一次探测脚本，取真实系统信息并缓存。
    func probeHostIfNeeded(_ host: Host) {
        guard let ssh = host.ssh, !ssh.host.isEmpty, !probingHosts.contains(host.id) else { return }
        probingHosts.insert(host.id)
        let id = host.id

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ssh.sshArguments(ephemeralKnownHosts: true) + ["-o", "BatchMode=no", Self.probeScript]
        var env = ProcessInfo.processInfo.environment
        if ssh.needsAskpass, let ap = SSHAskpass.envVars(password: ssh.password) {
            for (k, v) in ap { env[k] = v }
        }
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // 丢弃 stderr
        proc.terminationHandler = { [weak self] _ in
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in self?.applyProbe(id: id, output: text) }
        }

        do {
            try proc.run()
        } catch {
            probingHosts.remove(id)
            return
        }
        // 安全超时：20s 还没结束就杀掉，避免卡在认证
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if proc.isRunning { proc.terminate() }
        }
    }

    private func applyProbe(id: String, output: String) {
        probingHosts.remove(id)
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        var specs = HostSpecs()
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "OS": specs.os = val
            case "CORES": specs.cores = val
            case "MEM": specs.memory = val
            case "DISK": specs.disk = val
            default: break
            }
        }
        guard !specs.isEmpty else { return }   // 探测失败（连接/认证失败）则保留原样
        hosts[idx].specs = specs
        hosts[idx].status = .online            // 探测成功 ⇒ 一定在线
        HostStore.saveHosts(hosts)
    }

    // ---------- 在线状态检测 ----------
    /// 对所有主机做一次轻量 TCP 可达性检测（启动/刷新时调用）。
    func refreshAllStatuses() {
        for host in hosts { checkReachability(host) }
    }

    /// 轻量 TCP 连接探测（不登录）：实测握手 RTT，成功=在线+延迟，失败/超时=离线。
    func checkReachability(_ host: Host) {
        guard let ssh = host.ssh, !ssh.host.isEmpty else { return }
        let id = host.id
        let h = ssh.host
        let p = ssh.port
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (ok, ms) = Self.tcpPing(host: h, port: p, timeoutSec: 5)
            Task { @MainActor in self?.setStatus(id, ok ? .online : .offline, latencyMs: ok ? ms : nil) }
        }
    }

    /// 用非阻塞 socket connect 实测 TCP 握手耗时（毫秒）。返回 (是否连通, 延迟ms)。
    private static func tcpPing(host: String, port: Int, timeoutSec: Double) -> (Bool, Int) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res, let addr = info.pointee.ai_addr else {
            return (false, 0)
        }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return (false, 0) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let start = DispatchTime.now()
        let cr = connect(fd, addr, info.pointee.ai_addrlen)
        let elapsed = { Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000) }
        if cr == 0 { return (true, elapsed()) }            // 立即连通（如本机）
        if errno != EINPROGRESS { return (false, 0) }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pr = poll(&pfd, 1, Int32(timeoutSec * 1000))
        if pr <= 0 { return (false, 0) }                   // 超时或错误
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        if soErr != 0 { return (false, 0) }                // 连接被拒等
        return (true, elapsed())
    }

    private func setStatus(_ id: String, _ status: HostStatus, latencyMs: Int? = nil) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        // 运行时状态，不持久化（下次启动重新检测）
        if hosts[idx].status != status { hosts[idx].status = status }
        if hosts[idx].latencyMs != latencyMs { hosts[idx].latencyMs = latencyMs }
    }

    private var terminals: [Int: LocalProcessTerminalView] = [:]
    private var nextTabId = 1
    private var terminalCount = 0
    private var themeCancellable: AnyCancellable?

    private var settingsCancellable: AnyCancellable?

    init() {
        // 从磁盘加载主机与会话历史
        hosts = HostStore.loadHosts()
        sessions = HostStore.loadSessions()
        HostKeyVerifier.resetSession()   // 清空「仅本次信任」的会话临时 known_hosts
        // 启动即对所有主机做一次轻量在线检测
        defer { refreshAllStatuses() }

        // 所有用 Pal 配色的视图都已直接 @ObservedObject ThemeManager.shared / AppSettings.shared，
        // 无需再把它们的 objectWillChange 转发到 AppModel（那样会让整棵视图树重复重建）。
        // 这里只订阅副作用：主题/设置变化时刷新各终端的配色与透明度。
        themeCancellable = ThemeManager.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyThemeToTerminals() }
        }
        settingsCancellable = AppSettings.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyThemeToTerminals() }
        }
    }

    var activeHostId: String? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })?.hostId
    }

    /// 活动「会话」标签（终端/文件）对应的主机——侧栏文件树跟随它（概览页不算会话）。
    var activeSessionHost: Host? {
        guard let id = activeSessionTabId,
              let hid = tabs.first(where: { $0.id == id })?.hostId else { return nil }
        return hosts.first { $0.id == hid }
    }

    /// 活动「会话」标签的 id（文件树按标签分离时用作 key）。
    var activeSessionTabId: Int? {
        guard let id = activeTabId,
              let tab = tabs.first(where: { $0.id == id }),
              tab.kind == .terminal || tab.kind == .files,
              tab.hostId != nil else { return nil }
        return id
    }

    func host(_ id: String?) -> Host? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    // ---------- 终端 ----------
    func terminalView(for tabId: Int) -> LocalProcessTerminalView {
        if let tv = terminals[tabId] { return tv }
        let hostId = tabs.first(where: { $0.id == tabId })?.hostId
        let conn = hostId.flatMap { hid in hosts.first(where: { $0.id == hid })?.ssh }
        let tv = makeTerminal(ssh: conn, hostId: hostId, tabId: tabId)
        terminals[tabId] = tv
        return tv
    }

    /// 终端 cwd 变化（OSC 7）→ 定位该标签的侧栏文件树（按标签独立）。
    private var tabCwd: [Int: String] = [:]
    private var termDelegates: [Int: TerminalSessionDelegate] = [:]
    func handleTerminalCwd(tabId: Int, path: String) {
        guard tabCwd[tabId] != path else { return }   // 去重：同一目录不重复定位（OSC7 每次提示符都会发）
        tabCwd[tabId] = path
        fileTreeStates[tabId]?.reveal(path)
    }

    /// SSH 登录后注入的 OSC 7 钩子：bash/zsh 每次提示符上报当前目录。
    private static let osc7Hook =
        "__t7(){ printf '\\033]7;file://%s%s\\033\\\\' \"${HOSTNAME:-h}\" \"$PWD\"; }; " +
        "if [ -n \"$ZSH_VERSION\" ]; then precmd_functions+=(__t7); " +
        "else PROMPT_COMMAND=\"__t7;${PROMPT_COMMAND}\"; fi; __t7"

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

    // 终端默认 ANSI 调色板
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
        tv.installColors(ThemeManager.shared.isDark ? Self.darkPalette : Self.lightPalette)
        tv.nativeBackgroundColor = NSColor(hex: t.termBg)
        tv.nativeForegroundColor = NSColor(hex: t.termFg)
        tv.selectedTextBackgroundColor = NSColor(hex: t.termSelection)
        tv.caretColor = NSColor(hex: t.termCaret)
        tv.caretTextColor = NSColor(hex: t.termBg)
    }

    private func applyThemeToTerminals() {
        for tv in terminals.values {
            applyTheme(to: tv)
            // 强制全屏重绘，清掉旧的不透明像素
            tv.getTerminal().updateFullScreen()
            tv.setNeedsDisplay(tv.bounds)
        }
    }

    private func makeTerminal(ssh: SSHConnection? = nil, hostId: String? = nil, tabId: Int) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        tv.font = Self.terminalFont
        applyTheme(to: tv)

        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
        if !lang.uppercased().contains("UTF-8") {
            env.append("LANG=en_US.UTF-8")
        }

        if let ssh {
            // 真实 SSH 连接——密码用 OpenSSH 内置 SSH_ASKPASS 喂入（无需 sshpass）
            let args = ssh.sshArguments()
            if ssh.needsAskpass, let askpass = SSHAskpass.envVars(password: ssh.password) {
                for (k, v) in askpass { env.append("\(k)=\(v)") }
            }
            tv.startProcess(executable: "/usr/bin/ssh", args: args, environment: env)
            // 连接后注入 OSC7 钩子 + 初始命令 / 默认路径（best-effort）
            scheduleInitialCommands(tv, ssh: ssh)
        } else {
            let shell = AppSettings.shared.resolvedShell
            tv.startProcess(executable: shell, args: ["-l"], environment: env)
        }

        // 会话代理：cwd 跟踪（仅 SSH 主机）+ 进程退出（exit/掉线）自动关闭标签
        let d = TerminalSessionDelegate()
        if let hostId {
            d.onCwd = { [weak self] path in
                Task { @MainActor in self?.handleTerminalCwd(tabId: tabId, path: path) }
            }
        }
        d.onTerminated = { [weak self] in
            Task { @MainActor in self?.handleTerminalExit(tabId: tabId, hostId: hostId) }
        }
        tv.processDelegate = d
        termDelegates[tabId] = d
        return tv
    }

    /// SSH 终端进程退出（exit / 掉线）：关闭该标签（其文件树状态随之释放）。
    /// 若该主机已无其它会话标签，则断开复用的 ControlMaster 主连接。
    func handleTerminalExit(tabId: Int, hostId: String?) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        performCloseTab(tabId)   // 内部已清理该标签的 fileTreeState / tabCwd
        if let hostId, let host = hosts.first(where: { $0.id == hostId }) {
            let stillUsed = tabs.contains { ($0.kind == .terminal || $0.kind == .files) && $0.hostId == hostId }
            if !stillUsed { RemoteFS(host.ssh ?? SSHConnection()).closeMaster() }
        }
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

    private func scheduleInitialCommands(_ tv: LocalProcessTerminalView, ssh: SSHConnection) {
        let path = ssh.defaultPath.trimmingCharacters(in: .whitespaces)
        let cmd = ssh.initialCommand.trimmingCharacters(in: .whitespaces)
        // 总是注入 OSC7 钩子（用于 cwd 跟踪）；随后清屏隐藏该命令的回显（banner 仍保留在 scrollback，
        // 向上滚动可见），再附加可选的 cd / 初始命令（其输出落在清屏后的干净界面上）。
        var tail = ""
        if !path.isEmpty && path != "~" { tail += "cd \(path)" }
        if !cmd.isEmpty { tail += (tail.isEmpty ? "" : " && ") + cmd }
        var line = Self.osc7Hook + "; printf '\\033[2J\\033[H'"
        if !tail.isEmpty { line += "; " + tail }
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
        Task {
            guard await verifyHostKey(host) else { return }   // 首次连接先验证指纹
            connectingHost = host   // 展示连接进度弹窗，成功后 finishConnecting 进入终端
        }
    }

    /// 连接进度弹窗成功 → 打开真实终端标签。
    func finishConnecting() {
        guard let host = connectingHost else { return }
        connectingHost = nil
        addTab(.terminal, title: host.name, hostId: host.id)
        recordSession(hostId: host.id, kind: .terminal, detail: "终端会话")
    }

    func cancelConnecting() { connectingHost = nil }

    func openHostFiles(_ host: Host) {
        // 同一主机已有文件标签则切过去
        if let existing = tabs.first(where: { $0.kind == .files && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        Task {
            guard await verifyHostKey(host) else { return }
            addTab(.files, title: host.name, hostId: host.id)
            recordSession(hostId: host.id, kind: .files, detail: "文件浏览")
        }
    }

    /// 首次连接验证主机指纹：已知 → 直接放行；未知 → 弹窗让用户核对后决定。返回是否继续连接。
    func verifyHostKey(_ host: Host) async -> Bool {
        guard let ssh = host.ssh, !ssh.host.isEmpty else { return true }
        let h = ssh.host, p = ssh.port
        let pf = await Task.detached { HostKeyVerifier.preflight(host: h, port: p) }.value
        switch pf {
        case .known, .scanFailed:
            return true   // 已知放行；扫描失败交给 ssh 自己报错
        case .prompt(let info):
            let decision: HostKeyDecision = await withCheckedContinuation { cont in
                pendingHostKey = PendingHostKey(info: info) { cont.resume(returning: $0) }
            }
            pendingHostKey = nil
            switch decision {
            case .cancel: return false
            case .once: HostKeyVerifier.trust(info, persist: false); return true
            case .save: HostKeyVerifier.trust(info, persist: true); return true
            }
        }
    }

    // ---------- 文件浏览状态 ----------
    private var browserStates: [Int: BrowserState] = [:]

    func browserState(for tabId: Int, host: Host) -> BrowserState {
        if let s = browserStates[tabId] { return s }
        let s = BrowserState(fs: RemoteFS(host.ssh ?? SSHConnection()))
        browserStates[tabId] = s
        return s
    }

    /// 侧栏文件树状态（按主机缓存，活动栏「文件」用）。
    // 文件树状态按「标签」分离（同主机的多个会话各自独立）；底层 SSH 连接仍由 ControlMaster 按主机复用。
    private var fileTreeStates: [Int: FileTreeState] = [:]
    func fileTreeState(forTab tabId: Int, host: Host) -> FileTreeState {
        if let s = fileTreeStates[tabId] { return s }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: tabCwd[tabId])
        fileTreeStates[tabId] = s
        return s
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
        // 先清空代理回调，避免 terminate 触发的 processTerminated 再次回调（重入）
        if let d = termDelegates[id] { d.onTerminated = nil; d.onCwd = nil }
        // 终止子进程（SIGTERM）并关闭 PTY fd，避免孤儿 ssh/shell 进程与 fd 泄漏
        if let tv = terminals[id] {
            tv.process.terminate()
        }
        terminals.removeValue(forKey: id)
        termDelegates.removeValue(forKey: id)
        // 取消该标签未完成的文件操作并释放浏览/树状态（按标签独立，关即释放）
        browserStates[id]?.cancel()
        browserStates.removeValue(forKey: id)
        fileTreeStates.removeValue(forKey: id)
        tabCwd.removeValue(forKey: id)
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
