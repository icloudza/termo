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
    @Published var showAddRDPHost = false
    @Published var editingRDPHost: Host? = nil   // 非 nil 时以编辑模式打开 RDP 主机表单
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

    /// 新增一台 RDP（Windows 远程桌面）主机。
    func addRDPHost(name: String, group: String, notes: String, rdp: RDPConnection) {
        let id = "host-\(UUID().uuidString)"
        let newHost = Host(
            id: id,
            name: name,
            addr: "\(rdp.user)@\(rdp.host)",
            group: group,
            status: .unknown,
            os: "Windows",
            port: rdp.port,
            ssh: nil,
            notes: notes,
            rdp: rdp
        )
        hosts.append(newHost)
        HostStore.saveHosts(hosts)
        checkReachability(newHost)
    }

    /// 用编辑后的表单覆盖已有 RDP 主机（保持 id / 状态不变）。
    func updateRDPHost(id: String, name: String, group: String, notes: String, rdp: RDPConnection) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        let old = hosts[idx]
        hosts[idx] = Host(
            id: id,
            name: name,
            addr: "\(rdp.user)@\(rdp.host)",
            group: group,
            status: old.status,
            os: old.os,
            port: rdp.port,
            ssh: nil,
            notes: notes,
            rdp: rdp
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
    // 探测并发上限：最多 6 个并发 TCP 探测，控制线程/CPU 占用（大量主机时不会线程爆炸）。
    private static let reachQueue = DispatchQueue(label: "termo.reach", attributes: .concurrent)
    private static let reachLimit = DispatchSemaphore(value: 6)
    private var statusTimer: Timer?

    /// 对所有主机做一次轻量 TCP 可达性检测（启动/刷新/定时调用）。
    func refreshAllStatuses() {
        for host in hosts { checkReachability(host) }
    }

    /// 定时扫描在线状态/延迟；仅在 App 处于活动状态时运行（失焦即暂停，省 CPU）。
    private func startStatusTimer() {
        guard statusTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAllStatuses() }
        }
        t.tolerance = 5   // 允许系统合并定时器触发，进一步省电
        statusTimer = t
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// 轻量在线/延迟探测（不登录）：应用层测真实 RTT，成功=在线+延迟，失败/超时=离线。
    func checkReachability(_ host: Host) {
        let id = host.id
        let isRDP = host.isRDP
        let h: String, p: Int
        if let ssh = host.ssh, !ssh.host.isEmpty {
            h = ssh.host; p = ssh.port
        } else if let rdp = host.rdp, !rdp.host.isEmpty {
            h = rdp.host; p = rdp.port
        } else {
            return
        }
        Self.reachQueue.async { [weak self] in
            Self.reachLimit.wait()
            defer { Self.reachLimit.signal() }
            // RDP 端口无 SSH banner，只做纯 TCP 连通性；SSH 仍走带 1-RTT 测量的探测。
            let (ok, ms) = isRDP ? Self.tcpLatency(host: h, port: p) : Self.sshLatency(host: h, port: p)
            Task { @MainActor in self?.setStatus(id, ok ? .online : .offline, latencyMs: ms) }
        }
    }

    /// 纯 TCP 连通性探测（用于 RDP，没有可读 banner）：连上即在线，握手耗时作粗略延迟。
    private nonisolated static func tcpLatency(host: String, port: Int) -> (Bool, Int?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res, let addr = info.pointee.ai_addr else {
            return (false, nil)
        }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return (false, nil) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let t = DispatchTime.now()
        if connect(fd, addr, info.pointee.ai_addrlen) != 0 {
            if errno != EINPROGRESS { return (false, nil) }
            if !waitFD(fd, POLLOUT, 5) { return (false, nil) }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { return (false, nil) }
        }
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000)
        return (true, ms)
    }

    /// 应用层延迟测量：TCP 连到 SSH 端口判断在线，并在隧道建立后测一次纯 1-RTT。
    /// 注意纯 TCP/ICMP 握手在 TUN 模式代理下会被本地拦截（显示 ~2ms 假值），
    /// 故改为「收 banner（含代理建隧道开销，丢弃）→ 发版本 → 计时收服务器 KEXINIT」，
    /// 这次往返穿过代理到真实服务器，反映真实延迟。多采样取首个 ≥3ms 干净值（避开粘包假 0）。
    private nonisolated static func sshLatency(host: String, port: Int) -> (Bool, Int?) {
        var online = false
        var smallSample: Int? = nil
        for _ in 0..<3 {
            let (ok, rtt) = probeOnce(host: host, port: port, timeoutSec: 5)
            if ok { online = true }
            if let rtt {
                if rtt >= 3 { return (true, rtt) }   // 干净样本，直接用
                smallSample = rtt                    // <3ms：可能粘包，先记着，继续采样
            }
        }
        return (online, online ? smallSample : nil)
    }

    /// 单次探测：连接 → 读 banner → 发版本 → 计时读服务器 KEXINIT。返回 (TCP是否连通, 纯RTTms?)。
    private nonisolated static func probeOnce(host: String, port: Int, timeoutSec: Double) -> (Bool, Int?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res, let addr = info.pointee.ai_addr else {
            return (false, nil)
        }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return (false, nil) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // 1) 连接（非阻塞 + poll）
        if connect(fd, addr, info.pointee.ai_addrlen) != 0 {
            if errno != EINPROGRESS { return (false, nil) }
            if !waitFD(fd, POLLOUT, timeoutSec) { return (false, nil) }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { return (false, nil) }
        }
        // TCP 已连通 ⇒ 在线
        var buf = [UInt8](repeating: 0, count: 512)
        // 2) 读 banner（首包，含代理建隧道开销，丢弃）
        if !waitFD(fd, POLLIN, timeoutSec) { return (true, nil) }
        if recv(fd, &buf, buf.count, 0) <= 0 { return (true, nil) }
        // 3) 发我方版本，计时等服务器 KEXINIT（隧道已建立 ⇒ 纯 1 RTT）
        let ver = "SSH-2.0-termo\r\n"
        _ = ver.withCString { send(fd, $0, strlen($0), 0) }
        let t = DispatchTime.now()
        if !waitFD(fd, POLLIN, timeoutSec) { return (true, nil) }
        if recv(fd, &buf, buf.count, 0) <= 0 { return (true, nil) }
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000)
        return (true, ms)
    }

    /// 在 fd 上等待事件（POLLIN/POLLOUT），返回是否就绪（超时/错误返回 false）。
    private nonisolated static func waitFD(_ fd: Int32, _ event: Int32, _ timeoutSec: Double) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(event), revents: 0)
        return poll(&pfd, 1, Int32(timeoutSec * 1000)) > 0
    }

    private func setStatus(_ id: String, _ status: HostStatus, latencyMs: Int? = nil) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        // 运行时状态，不持久化（下次启动重新检测）
        if hosts[idx].status != status { hosts[idx].status = status }
        if hosts[idx].latencyMs != latencyMs { hosts[idx].latencyMs = latencyMs }
    }

    private var terminals: [Int: LocalProcessTerminalView] = [:]
    private var rdpSessions: [Int: RDPSession] = [:]
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
            DispatchQueue.main.async {
                self?.applyThemeToTerminals()
                self?.applyTerminalSettings()
            }
        }

        // 定时扫描在线状态/延迟：App 活动时每 30s 一次，失焦暂停（省 CPU/电）
        startStatusTimer()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startStatusTimer(); self?.refreshAllStatuses() }
        }
        nc.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopStatusTimer() }
        }
    }

    var activeHostId: String? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })?.hostId
    }

    /// 侧栏「文件」面板要显示的树 + 稳定标识 + 所属主机。
    /// 终端/文件标签 → 各自跟随 cwd 的按标签树；编辑器标签 → 主机级资源管理器树（高亮当前文件）。
    var sidebarFileTree: (state: FileTreeState, id: String, host: Host)? {
        guard let id = activeTabId,
              let tab = tabs.first(where: { $0.id == id }),
              let host = host(tab.hostId) else { return nil }
        switch tab.kind {
        case .terminal, .files:
            return (fileTreeState(forTab: id, host: host), "tab-\(id)", host)
        case .editor:
            return (explorerTree(for: host), "host-\(host.id)", host)
        case .overview, .rdp:
            return nil
        }
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

    /// 当前终端字体（按设置；空名或找不到则回退到预置等宽字体）。
    private func currentTerminalFont() -> NSFont {
        let size = CGFloat(AppSettings.shared.termFontSize)
        let name = AppSettings.shared.termFont
        if !name.isEmpty, let f = NSFont(name: name, size: size) { return f }
        for n in ["JetBrainsMono Nerd Font", "MesloLGM Nerd Font", "MesloLGS Nerd Font",
                  "Hack Nerd Font", "FiraCode Nerd Font", "FiraCode Nerd Font Mono"] {
            if let f = NSFont(name: n, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 按设置（形状 + 闪烁）得到 SwiftTerm 光标样式。
    private func currentCursorStyle() -> CursorStyle {
        let blink = AppSettings.shared.termCursorBlink
        switch AppSettings.shared.termCursorStyle {
        case "bar": return blink ? .blinkBar : .steadyBar
        case "underline": return blink ? .blinkUnderline : .steadyUnderline
        default: return blink ? .blinkBlock : .steadyBlock
        }
    }

    /// 应用光标样式与滚动缓冲到某终端。
    private func applyTerminalConfig(to tv: LocalProcessTerminalView) {
        let term = tv.getTerminal()
        term.setCursorStyle(currentCursorStyle())
        term.changeScrollback(AppSettings.shared.termScrollback)
    }

    /// 设置变化时刷新所有终端的字体/光标/滚动缓冲。
    private func applyTerminalSettings() {
        let font = currentTerminalFont()
        for tv in terminals.values {
            tv.font = font
            applyTerminalConfig(to: tv)
            tv.setNeedsDisplay(tv.bounds)
        }
    }

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
        tv.font = currentTerminalFont()
        applyTheme(to: tv)
        applyTerminalConfig(to: tv)

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
        // 立刻显示连接弹窗；指纹验证与真实连接都在弹窗内分步进行（避免海外高延迟主机点击后长时间无反馈）
        connectingHost = host
    }

    /// 连接进度弹窗成功 → 打开真实终端标签。
    func finishConnecting() {
        guard let host = connectingHost else { return }
        connectingHost = nil
        addTab(.terminal, title: host.name, hostId: host.id)
        recordSession(hostId: host.id, kind: .terminal, detail: "终端会话")
        prewarmExplorer(for: host)
    }

    /// SSH 连上后立刻在后台预建主机资源管理器树，使后续打开文件无可感知的加载。
    func prewarmExplorer(for host: Host) {
        guard host.ssh != nil else { return }
        explorerTree(for: host).startIfNeeded()
    }

    func cancelConnecting() { connectingHost = nil }

    // ---------- RDP 远程桌面 ----------
    /// 打开（或切到）一台 RDP 主机的远程桌面标签。
    func openHostRDP(_ host: Host) {
        guard host.isRDP else { return }
        if let existing = tabs.first(where: { $0.kind == .rdp && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        let id = addTab(.rdp, title: host.name, hostId: host.id)
        rdpSessions[id] = RDPSession(host: host)
        recordSession(hostId: host.id, kind: .rdp, detail: "远程桌面")
    }

    /// 某 RDP 标签的会话状态（缺失则按需创建，保证视图总能拿到）。
    func rdpSession(for tabId: Int, host: Host) -> RDPSession {
        if let s = rdpSessions[tabId] { return s }
        let s = RDPSession(host: host)
        rdpSessions[tabId] = s
        return s
    }

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
            prewarmExplorer(for: host)
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

    /// 主机级「资源管理器」树（所有编辑器标签共用一棵，高亮跟随当前打开的文件，不随每个文件重载）。
    private var hostExplorerTrees: [String: FileTreeState] = [:]
    func explorerTree(for host: Host) -> FileTreeState {
        if let s = hostExplorerTrees[host.id] { return s }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: nil)
        hostExplorerTrees[host.id] = s
        return s
    }

    /// 面包屑点击：切到「文件」侧栏并在资源管理器里展开/选中该路径（目录或文件）。
    func jumpToExplorer(path: String, host: Host) {
        section = .files
        revealInExplorer(path, host: host)
    }

    /// 在主机资源管理器树里展开并选中某文件（已存在则原地 reveal，不存在则以该路径初始化）。
    private func revealInExplorer(_ path: String, host: Host) {
        if let tree = hostExplorerTrees[host.id] {
            tree.reveal(path)
        } else {
            hostExplorerTrees[host.id] = FileTreeState(
                fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: path)
        }
    }

    @discardableResult
    private func addTab(_ kind: TabKind, title: String, hostId: String?, filePath: String? = nil) -> Int {
        let id = nextTabId
        nextTabId += 1
        tabs.append(TabItem(id: id, kind: kind, title: title, hostId: hostId, filePath: filePath))
        activeTabId = id
        return id
    }

    // ---------- 文件编辑 / 预览 ----------
    private var editorStates: [Int: EditorState] = [:]

    func editorState(for tabId: Int) -> EditorState? { editorStates[tabId] }

    /// 打开一个远程文件到编辑器/预览标签（同主机同路径已开则切过去）。
    func openFile(_ file: RemoteFile, host: Host) {
        guard !file.isDir else { return }
        revealInExplorer(file.path, host: host)   // 左侧资源管理器高亮到该文件
        if let existing = tabs.first(where: {
            $0.kind == .editor && $0.hostId == host.id && $0.filePath == file.path
        }) {
            activeTabId = existing.id
            return
        }
        let id = addTab(.editor, title: file.name, hostId: host.id, filePath: file.path)
        let st = EditorState(file: file, host: host, fs: RemoteFS(host.ssh ?? SSHConnection()))
        editorStates[id] = st
        st.loadIfNeeded()   // 立刻开始加载（点击即拉取，不等视图出现）
    }

    func selectTab(_ id: Int) {
        activeTabId = id
        // 切到编辑器标签时，让资源管理器高亮跟到它打开的文件
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .editor,
           let path = tab.filePath, let host = host(tab.hostId) {
            revealInExplorer(path, host: host)
        }
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
        editorStates[id]?.cancel()
        editorStates.removeValue(forKey: id)
        rdpSessions[id]?.disconnect()
        rdpSessions.removeValue(forKey: id)
        tabCwd.removeValue(forKey: id)
        if activeTabId == id {
            activeTabId = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
    }

    /// 该终端是否有正在运行的活跃进程，需要确认后再关闭。
    private func shouldConfirmClose(_ id: Int) -> Bool {
        // 编辑器有未保存修改 → 始终确认（数据丢失风险，不受「关闭确认」开关影响）
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .editor {
            return editorStates[id]?.isDirty ?? false
        }
        guard AppSettings.shared.closeConfirm else { return false }
        // RDP 会话：关闭即断开远程桌面，始终确认
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .rdp { return true }
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

    /// 关闭确认弹窗标题（按标签类型区分）。
    var pendingCloseDialogTitle: String {
        guard let id = pendingCloseTabId,
              let tab = tabs.first(where: { $0.id == id }) else { return "关闭此标签？" }
        switch tab.kind {
        case .editor: return "放弃未保存的修改？"
        case .rdp:    return "断开远程桌面？"
        default:      return "关闭此终端？"
        }
    }

    /// 关闭确认弹窗正文。
    var pendingCloseDialogMessage: String {
        guard let id = pendingCloseTabId,
              let tab = tabs.first(where: { $0.id == id }) else { return "" }
        switch tab.kind {
        case .editor: return "「\(tab.title)」有尚未保存的修改，关闭后修改将丢失。"
        case .rdp:    return "「\(tab.title)」是一个远程桌面会话，关闭后将断开连接。"
        default:      return "「\(tab.title)」有正在运行的进程，关闭后进程将被终止。"
        }
    }
}
