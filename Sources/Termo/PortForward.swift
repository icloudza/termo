import Foundation

/// 端口转发类型，对应 OpenSSH 的 -L / -R / -D。
enum ForwardKind: String, Codable, CaseIterable {
    case local, remote, dynamic

    var title: String {
        switch self {
        case .local:   return "本地"
        case .remote:  return "远程"
        case .dynamic: return "动态"
        }
    }

    /// 表单字段下方的释义，点明「目标地址相对 SSH 另一端解析」这一最易混淆处。
    var hint: String {
        switch self {
        case .local:
            return "在本机开一个监听端口，连进来的流量经隧道送到「目标」——目标地址由服务器解析，故 localhost 指服务器自身（访问只监听内网的远程服务）。"
        case .remote:
            return "在服务器上开一个监听端口，连进来的流量经隧道送回本机能访问的「目标」（把本地服务暴露给服务器侧）。"
        case .dynamic:
            return "在本机开一个 SOCKS5 代理端口，应用走它即可让流量从服务器出口（无需指定目标）。"
        }
    }
}

/// 一条端口转发规则。绑定到某主机，持久化（不含运行态）。
struct ForwardRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var hostId: String
    var name: String = ""
    var kind: ForwardKind = .local
    var bindAddress: String = "127.0.0.1"   // 监听端绑定地址；本机用 127.0.0.1，开放给局域网用 0.0.0.0
    var listenPort: Int = 0                  // 监听端口
    var destHost: String = "localhost"       // 目标主机（dynamic 不用）
    var destPort: Int = 0                    // 目标端口（dynamic 不用）

    /// 兼容解码：缺字段按默认值，避免旧 forwards.json 整体加载失败。
    enum CodingKeys: String, CodingKey {
        case id, hostId, name, kind, bindAddress, listenPort, destHost, destPort
    }
    init(id: UUID = UUID(), hostId: String, name: String = "", kind: ForwardKind = .local,
         bindAddress: String = "127.0.0.1", listenPort: Int = 0,
         destHost: String = "localhost", destPort: Int = 0) {
        self.id = id; self.hostId = hostId; self.name = name; self.kind = kind
        self.bindAddress = bindAddress; self.listenPort = listenPort
        self.destHost = destHost; self.destPort = destPort
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        hostId = try c.decodeIfPresent(String.self, forKey: .hostId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(ForwardKind.self, forKey: .kind) ?? .local
        bindAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        listenPort = try c.decodeIfPresent(Int.self, forKey: .listenPort) ?? 0
        destHost = try c.decodeIfPresent(String.self, forKey: .destHost) ?? "localhost"
        destPort = try c.decodeIfPresent(Int.self, forKey: .destPort) ?? 0
    }

    /// 传给 ssh 的转发参数（作为独立 argv，不经 shell，无注入风险）。
    var sshForwardFlags: [String] {
        let bind = bindAddress.trimmingCharacters(in: .whitespaces)
        let prefix = bind.isEmpty ? "" : "\(bind):"
        switch kind {
        case .local:   return ["-L", "\(prefix)\(listenPort):\(destHost):\(destPort)"]
        case .remote:  return ["-R", "\(prefix)\(listenPort):\(destHost):\(destPort)"]
        case .dynamic: return ["-D", "\(prefix)\(listenPort)"]
        }
    }

    /// 列表里展示的 from → to 摘要。
    var summary: String {
        let bind = bindAddress.isEmpty ? "127.0.0.1" : bindAddress
        switch kind {
        case .local:   return "\(bind):\(listenPort) → \(destHost):\(destPort)"
        case .remote:  return "\(bind):\(listenPort) ← \(destHost):\(destPort)"
        case .dynamic: return "SOCKS5 \(bind):\(listenPort)"
        }
    }

    /// 校验：监听端口必填合法；local/remote 还需合法的目标主机与端口。
    var validationError: String? {
        guard (1...65535).contains(listenPort) else { return "监听端口需在 1–65535 之间" }
        if kind != .dynamic {
            if destHost.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写目标主机" }
            guard (1...65535).contains(destPort) else { return "目标端口需在 1–65535 之间" }
        }
        return nil
    }
}

/// 进程级登记表：记录所有存活的转发子进程，供 App 退出时统一清理。
/// ssh -N 不写 stdout，不会像监控进程那样随父进程死亡触发 SIGPIPE 自然退出，必须显式终止以免残留。
/// 用锁保护，可在任意线程（含退出通知的同步回调）安全调用，规避 MainActor 隔离与 macOS 14 才有的 assumeIsolated。
final class ForwardProcessRegistry: @unchecked Sendable {
    static let shared = ForwardProcessRegistry()
    private let lock = NSLock()
    private var procs: [ObjectIdentifier: Process] = [:]

    func register(_ p: Process) { lock.lock(); procs[ObjectIdentifier(p)] = p; lock.unlock() }
    func unregister(_ p: Process) { lock.lock(); procs[ObjectIdentifier(p)] = nil; lock.unlock() }
    func terminateAll() {
        lock.lock(); let all = Array(procs.values); procs.removeAll(); lock.unlock()
        for p in all where p.isRunning { p.terminate() }
    }
}

/// 单台主机的端口转发运行态管理：每条已启动的规则对应一个 `ssh -N` 子进程。
/// 复用现有 SSH 凭证与 askpass，服务器零安装；进程退出即视为转发失败/断开。
@MainActor
final class ForwardManager: ObservableObject {
    enum RuleStatus: Equatable {
        case stopped, starting, active, failed(String)

        var isRunning: Bool {
            switch self { case .starting, .active: return true; default: return false }
        }
    }

    private let ssh: SSHConnection
    @Published private(set) var statuses: [UUID: RuleStatus] = [:]
    private var procs: [UUID: Process] = [:]
    private var graceWork: [UUID: DispatchWorkItem] = [:]
    private var stderrBuf: [UUID: String] = [:]

    // 看门狗状态：intended = 用户期望保持运行的规则；startedRules 留存其配置以便自动重启；
    // failCount 驱动退避；restartWork 记录已排程的重启（去重，避免叠加）。
    private var intended: Set<UUID> = []
    private var startedRules: [UUID: ForwardRule] = [:]
    private var failCount: [UUID: Int] = [:]
    private var restartWork: [UUID: DispatchWorkItem] = [:]

    // 宽限期：进程存活超过此时长仍未退出，视为转发已建立。配合 ExitOnForwardFailure，
    // 端口被占用 / 转发被拒等失败会让 ssh 提前退出，从而在宽限期内被判为失败。
    private static let graceSeconds: TimeInterval = 1.2
    // 自动重启退避：base * 2^失败次数，封顶 cap。短暂网络抖动由 ssh 自带 ServerAliveInterval 容忍，
    // 进程真正退出后才走重启；离线时不重启（等网络恢复回调统一拉起），避免抖动期反复重连。
    private static let backoffBase: TimeInterval = 2
    private static let backoffCap: TimeInterval = 30

    init(ssh: SSHConnection) { self.ssh = ssh }

    func status(_ id: UUID) -> RuleStatus { statuses[id] ?? .stopped }

    /// 是否有用户期望保持运行的隧道（供看门狗判断是否需要 tick）。
    var hasIntended: Bool { !intended.isEmpty }

    /// 用户主动启动：标记为期望运行、清零退避，然后拉起。
    func start(_ rule: ForwardRule) {
        intended.insert(rule.id)
        startedRules[rule.id] = rule
        failCount[rule.id] = 0
        restartWork[rule.id]?.cancel(); restartWork[rule.id] = nil
        launch(rule)
    }

    /// 拉起一条隧道的子进程（start 与自动重启共用；不改 intended/退避）。
    private func launch(_ rule: ForwardRule) {
        guard procs[rule.id] == nil else { return }
        guard NetworkMonitor.shared.isOnline else { statuses[rule.id] = .failed("等待网络"); return }
        guard !ssh.host.isEmpty else { statuses[rule.id] = .failed("主机未配置"); return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -N 只建隧道不开 shell；ExitOnForwardFailure 让转发建立失败时 ssh 立即退出（而非空连着）。
        proc.arguments = ssh.sshArguments()
            + ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=no"]
            + rule.sshForwardFlags
        var env = ProcessInfo.processInfo.environment
        if ssh.needsAskpass, let ap = SSHAskpass.envVars(password: ssh.password) {
            for (k, v) in ap { env[k] = v }
        }
        proc.environment = env

        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        stderrBuf[rule.id] = ""
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.stderrBuf[rule.id, default: ""] += s }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleExit(rule.id) }
        }

        do {
            try proc.run()
            procs[rule.id] = proc
            ForwardProcessRegistry.shared.register(proc)
            statuses[rule.id] = .starting
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.graceWork[rule.id] = nil
                if self.procs[rule.id]?.isRunning == true {
                    self.statuses[rule.id] = .active
                    self.failCount[rule.id] = 0   // 稳定建立即清零退避
                }
            }
            graceWork[rule.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.graceSeconds, execute: work)
        } catch {
            statuses[rule.id] = .failed("启动失败")
        }
    }

    /// 终止子进程并清理其登记，但不改 intended/退避（供 stop 与网络重连复用）。
    private func teardown(_ id: UUID) {
        graceWork[id]?.cancel(); graceWork[id] = nil
        if let p = procs[id] {
            p.terminationHandler = nil   // 主动终止，不触发失败/重启判定
            (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            ForwardProcessRegistry.shared.unregister(p)
            if p.isRunning { p.terminate() }
        }
        procs[id] = nil
    }

    /// 用户主动停止：取消期望、清退避与待重启，然后终止。
    func stop(_ id: UUID) {
        intended.remove(id)
        failCount[id] = nil
        restartWork[id]?.cancel(); restartWork[id] = nil
        teardown(id)
        statuses[id] = .stopped
    }

    func stopAll() { for id in Set(procs.keys).union(intended) { stop(id) } }

    /// 网络切换：离线时取消待重启等待恢复；恢复在线时清零退避、立即重连所有期望运行的隧道。
    func handleNetworkChange() {
        if !NetworkMonitor.shared.isOnline {
            for (_, w) in restartWork { w.cancel() }
            restartWork.removeAll()
            return
        }
        for id in intended {
            guard let rule = startedRules[id] else { continue }
            restartWork[id]?.cancel(); restartWork[id] = nil
            failCount[id] = 0
            teardown(id)            // 旧连接已随网络失效，丢弃重连
            launch(rule)
        }
    }

    /// 看门狗周期巡检：在线时，把「期望运行却已掉线、且无待重启」的隧道补排一次重启。
    /// 兜底意外漏掉的进程退出信号；离线时跳过（等网络恢复回调统一处理）。
    func watchdogTick() {
        guard NetworkMonitor.shared.isOnline else { return }
        for id in intended where !status(id).isRunning && restartWork[id] == nil {
            scheduleRestart(id)
        }
    }

    // 永久性失败：重试也无济于事（需用户改配置/释放端口），看门狗不自动重启，留待手动处理。
    private static let fatalReasons: Set<String> = ["本地端口已被占用", "认证失败", "转发请求被拒绝", "主机无法解析"]

    private func handleExit(_ id: UUID) {
        // 主动 stop 已把 procs[id] 置 nil 且摘掉 handler；走到这里即意外退出。
        guard let p = procs[id] else { return }
        graceWork[id]?.cancel(); graceWork[id] = nil
        ForwardProcessRegistry.shared.unregister(p)
        procs[id] = nil
        let reason = Self.failureReason(from: stderrBuf[id] ?? "")
        statuses[id] = .failed(reason)
        guard intended.contains(id) else { return }
        if Self.fatalReasons.contains(reason) {
            // 永久性失败：撤销期望运行，避免看门狗反复无效重试（用户修正后可手动重启）
            intended.remove(id); failCount[id] = nil
            restartWork[id]?.cancel(); restartWork[id] = nil
        } else {
            scheduleRestart(id)   // 瞬时失败（断线/超时）→ 退避后自动重启
        }
    }

    /// 退避后自动重启一条期望运行的隧道（去重、离线不排程）。
    private func scheduleRestart(_ id: UUID) {
        guard intended.contains(id), restartWork[id] == nil else { return }
        guard NetworkMonitor.shared.isOnline, startedRules[id] != nil else { return }
        let n = failCount[id] ?? 0
        let delay = min(Self.backoffBase * pow(2, Double(n)), Self.backoffCap)
        failCount[id] = n + 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork[id] = nil
            guard self.intended.contains(id), NetworkMonitor.shared.isOnline,
                  !self.status(id).isRunning, let rule = self.startedRules[id] else { return }
            self.launch(rule)
        }
        restartWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 把 ssh 的 stderr 翻译成简短中文原因。
    static func failureReason(from err: String) -> String {
        let e = err.lowercased()
        if e.contains("address already in use") || e.contains("cannot listen to port") { return "本地端口已被占用" }
        if e.contains("permission denied") { return "认证失败" }
        if e.contains("connection refused") { return "目标拒绝连接" }
        if e.contains("could not request") || (e.contains("forwarding") && e.contains("fail")) { return "转发请求被拒绝" }
        if e.contains("name or service not known") || e.contains("could not resolve") { return "主机无法解析" }
        if e.contains("timed out") || e.contains("timeout") { return "连接超时" }
        if e.isEmpty { return "连接已断开" }
        return "连接失败"
    }
}
