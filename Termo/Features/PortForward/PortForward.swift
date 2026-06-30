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

/// 进程级登记表：记录所有存活的 libssh2 转发隧道的关闭动作，供 App 退出时统一清理（释放 -R 的服务器端监听）。
/// 用锁保护，可在任意线程（含退出通知的同步回调）安全调用，规避 MainActor 隔离与 macOS 14 才有的 assumeIsolated。
/// 注：libssh2 转发是进程内线程+socket，随进程死亡自动回收；本表主要做优雅收尾。
final class ForwardProcessRegistry: @unchecked Sendable {
    static let shared = ForwardProcessRegistry()
    private let lock = NSLock()
    private var items: [Int: () -> Void] = [:]
    private var nextId = 0

    /// 登记一个关闭动作，返回句柄。
    func register(_ close: @escaping () -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextId; nextId += 1; items[id] = close; return id
    }
    func unregister(_ id: Int) { lock.lock(); items[id] = nil; lock.unlock() }
    func terminateAll() {
        lock.lock(); let all = Array(items.values); items.removeAll(); lock.unlock()
        for close in all { close() }
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
    // [SSH 迁移] 每条隧道 = 一条 dedicated libssh2 会话 + 一个 C 层 pump（TermoSSHForward*）。
    private var sessions: [UUID: SSHSession] = [:]
    private var forwards: [UUID: OpaquePointer] = [:]        // TermoSSHForward*
    private var boxes: [UUID: UnsafeMutableRawPointer] = [:] // on_state 回调载体（StateBox 经 Unmanaged）
    private var regIds: [UUID: Int] = [:]                    // 退出登记表句柄

    // 看门狗状态：intended = 用户期望保持运行的规则；startedRules 留存其配置以便自动重启；
    // failCount 驱动退避；restartWork 记录已排程的重启（去重，避免叠加）。
    private var intended: Set<UUID> = []
    private var startedRules: [UUID: ForwardRule] = [:]
    private var failCount: [UUID: Int] = [:]
    private var restartWork: [UUID: DispatchWorkItem] = [:]

    // 自动重启退避：base * 2^失败次数，封顶 cap。离线时不重启（等网络恢复回调统一拉起）。
    private static let backoffBase: TimeInterval = 2
    private static let backoffCap: TimeInterval = 30
    // 致命失败（重试无益，需用户改配置/释放端口）：看门狗不自动重启。
    private static let fatalSubstrings = ["端口已被占用", "认证", "主机密钥", "转发请求被拒绝", "主机未配置"]

    /// on_state(ok=0) 异步断开回调的载体。
    private final class StateBox {
        let cb: (String) -> Void
        init(_ cb: @escaping (String) -> Void) { self.cb = cb }
    }

    init(ssh: SSHConnection) { self.ssh = ssh }

    func status(_ id: UUID) -> RuleStatus { statuses[id] ?? .stopped }

    /// 是否有「致命失败」的隧道（端口占用/认证失败/转发被拒等，已撤销自动重试）。供托盘红灯。
    /// 只算不再重试的 —— 排除掉线后正在退避重连的瞬时 .failed，避免红灯频闪。
    var hasFatalFailure: Bool {
        statuses.contains { id, status in
            if case .failed = status { return !intended.contains(id) }
            return false
        }
    }

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

    /// 拉起一条隧道（start 与自动重启共用；不改 intended/退避）：后台建 dedicated 会话 + 开 C 层转发。
    private func launch(_ rule: ForwardRule) {
        guard forwards[rule.id] == nil, sessions[rule.id] == nil else { return }
        guard NetworkMonitor.shared.isOnline else { statuses[rule.id] = .failed("等待网络"); return }
        guard !ssh.host.isEmpty else { statuses[rule.id] = .failed("主机未配置"); return }

        statuses[rule.id] = .starting
        let conn = ssh
        let id = rule.id
        let kind: Int32 = rule.kind == .local ? 0 : (rule.kind == .remote ? 1 : 2)
        let (bind, lport, dhost, dport) = (rule.bindAddress, rule.listenPort, rule.destHost, rule.destPort)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let a = conn.libssh2Auth
            let session: SSHSession
            do {
                session = try SSHSession.connect(host: conn.host, port: conn.port, user: conn.user,
                                                 password: a.password, keyPath: a.keyPath, keyPassphrase: a.keyPassphrase)
            } catch {
                let msg = (error as? SSHSession.SSHError)?.message ?? "连接失败"
                Task { @MainActor in self?.onFailure(id, reason: msg) }
                return
            }
            guard let raw = session.rawHandle else {
                session.close()
                Task { @MainActor in self?.onFailure(id, reason: "连接失败") }
                return
            }
            let box = Unmanaged.passRetained(StateBox { msg in
                Task { @MainActor in self?.onDropped(id, reason: msg) }
            }).toOpaque()
            var err = [CChar](repeating: 0, count: 256)
            guard let fwd = termo_ssh_forward_open(raw, kind, bind, Int32(lport), dhost, Int32(dport),
                                                   { ud, ok, msg in
                                                       guard let ud, ok == 0 else { return }
                                                       Unmanaged<StateBox>.fromOpaque(ud).takeUnretainedValue()
                                                           .cb(msg.map { String(cString: $0) } ?? "连接已断开")
                                                   }, box, &err, 256) else {
                Unmanaged<StateBox>.fromOpaque(box).release()
                session.close()
                let reason = String(cString: err)
                Task { @MainActor in self?.onFailure(id, reason: reason) }
                return
            }
            Task { @MainActor in self?.onEstablished(id, session: session, forward: fwd, box: box) }
        }
    }

    /// 后台建立成功：登记并标记 active（若期间已被 stop，则就地拆掉）。
    private func onEstablished(_ id: UUID, session: SSHSession, forward: OpaquePointer, box: UnsafeMutableRawPointer) {
        guard intended.contains(id) else {
            termo_ssh_forward_close(forward); session.close()
            Unmanaged<StateBox>.fromOpaque(box).release()
            return
        }
        sessions[id] = session
        forwards[id] = forward
        boxes[id] = box
        regIds[id] = ForwardProcessRegistry.shared.register {
            termo_ssh_forward_close(forward); session.close()
        }
        statuses[id] = .active
        failCount[id] = 0
    }

    /// 建立失败（连接/认证/监听）：标记失败；致命则不重试，瞬时则退避重启。
    private func onFailure(_ id: UUID, reason: String) {
        statuses[id] = .failed(reason)
        guard intended.contains(id) else { return }
        if Self.fatalSubstrings.contains(where: { reason.contains($0) }) {
            intended.remove(id); failCount[id] = nil
            restartWork[id]?.cancel(); restartWork[id] = nil
        } else {
            scheduleRestart(id)
        }
    }

    /// 运行中异步断开（C 层 on_state 回调）：拆除并按瞬时失败重启。
    private func onDropped(_ id: UUID, reason: String) {
        guard sessions[id] != nil else { return }   // 已被 stop/teardown → 忽略
        teardown(id)
        statuses[id] = .failed(reason.isEmpty ? "连接已断开" : reason)
        guard intended.contains(id) else { return }
        scheduleRestart(id)
    }

    /// 关闭转发 + 会话并清理登记，但不改 intended/退避（供 stop 与网络重连复用）。
    private func teardown(_ id: UUID) {
        if let regId = regIds[id] { ForwardProcessRegistry.shared.unregister(regId); regIds[id] = nil }
        if let fwd = forwards[id] { termo_ssh_forward_close(fwd); forwards[id] = nil }   // 停 pump（join）后无更多回调
        if let box = boxes[id] { Unmanaged<StateBox>.fromOpaque(box).release(); boxes[id] = nil }
        if let s = sessions[id] { s.close(); sessions[id] = nil }
    }

    /// 用户主动停止：取消期望、清退避与待重启，然后终止。
    func stop(_ id: UUID) {
        intended.remove(id)
        failCount[id] = nil
        restartWork[id]?.cancel(); restartWork[id] = nil
        teardown(id)
        statuses[id] = .stopped
    }

    func stopAll() { for id in Set(forwards.keys).union(intended) { stop(id) } }

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
}
