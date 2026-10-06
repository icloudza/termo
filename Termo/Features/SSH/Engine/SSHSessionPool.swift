import Foundation

// MARK: - 从连接配置派生 libssh2 认证参数

extension SSHConnection {
    /// 把连接配置映射成 libssh2 认证三元组：
    /// - 密钥登录：落地库密钥(keyId)或手填路径(keyPath)，passphrase 取 password 字段；
    /// - 密码 / 每次询问：用已保存/本会话输入的 password 走密码认证。
    var libssh2Auth: (password: String?, keyPath: String?, keyPassphrase: String?) {
        if authMethod == .key {
            let path = keyId.isEmpty ? keyPath : (KeyMaterializer.path(forKeyId: keyId) ?? keyPath)
            return (nil, path.isEmpty ? nil : path, password.isEmpty ? nil : password)
        }
        return (password.isEmpty ? nil : password, nil, nil)
    }

    /// 连接复用键：目标 + 影响连接的设置（凭据/代理/算法）。设置一变就是另一把键，不会复用按旧配置建立的连接。
    var poolKey: String {
        [host, String(port), user, authMethod.rawValue, password, keyId, keyPath, disableProxy ? "1" : "0",
         proxyURL, ciphers, kexAlgos, hostKeyAlgos].joined(separator: "\u{1F}")
    }

    /// 代理设置解析结果。type：0 直连 1 SOCKS5 2 SOCKS4a 3 HTTP CONNECT -1 地址无效（拒绝连接，绝不静默直连）。
    var proxySpec: (type: Int32, host: String, port: Int, user: String, pass: String) {
        var raw = proxyURL.trimmingCharacters(in: .whitespaces)
        guard !disableProxy, !raw.isEmpty else { return (0, "", 0, "", "") }
        // 早年允许不带协议头（如 127.0.0.1:7890）：按 SOCKS5 理解（ssh 走代理最常见的类型；类型不对会报「代理响应异常」）
        if !raw.contains("://") { raw = "socks5://" + raw }
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(),
              let h = c.host, !h.isEmpty else { return (-1, "", 0, "", "") }
        let type: Int32
        switch scheme {
        case "socks5", "socks5h": type = 1
        case "socks4", "socks4a": type = 2
        case "http", "https": type = 3          // https:// 与旧版 nc -X connect 一致，按 HTTP CONNECT 处理
        default: return (-1, "", 0, "", "")
        }
        return (type, h, c.port ?? (type == 3 ? 8080 : 1080), c.user ?? "", c.password ?? "")
    }

    /// 把主机的代理/算法/超时设置转成 C 层选项（字符串仅在 body 执行期间有效）。
    func withSSHOptions<R>(_ body: (UnsafePointer<TermoSSHOptions>) throws -> R) rethrows -> R {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar>? {
            guard !s.isEmpty, let p = strdup(s) else { return nil }
            owned.append(p)
            return UnsafePointer(p)
        }
        let px = proxySpec
        var o = TermoSSHOptions()
        o.proxy_type = px.type
        o.proxy_host = c(px.host)
        o.proxy_port = Int32(px.port)
        o.proxy_user = c(px.user)
        o.proxy_pass = c(px.pass)
        o.ciphers = c(ciphers)
        o.kex = c(kexAlgos)
        o.hostkey_algos = c(hostKeyAlgos.isEmpty ? (HostKeyAlgoPreference.get(host: host, port: port) ?? "") : hostKeyAlgos)
        o.connect_timeout_sec = Int32(timeoutMs > 0 ? max(1, timeoutMs / 1000) : 0)
        o.keepalive_sec = Int32(heartbeatMs > 0 ? max(1, heartbeatMs / 1000) : 0)
        return try withUnsafePointer(to: &o) { try body($0) }
    }
}

// MARK: - 进程级每主机会话池

/// 进程级 **每主机 libssh2 会话池**，替代旧的 OpenSSH ControlMaster。
///
/// 设计要点：
/// - **短操作**走 `withSession`：从该主机的暖连接里借一条、跑完归还。认证只在首次建连时摊销，
///   后续操作复用暖连接；并发的多个短操作各借到**不同**连接 → 天然并发（不像单条会话那样互相串行）。
/// - **长跑/流式操作**（终端 PTY、上传/下载、后台监控、远端解压）走 `dedicated`：独占一条连接、
///   用完即关，**绝不**占用池内连接去阻塞别的操作（解决“解压时无法浏览”的根因）。
/// - 单条 `SSHSession` 仍非线程安全，但池保证一条连接同一时刻只被一个借用方持有，借出期间独占。
///
/// 这是 RemoteFS（文件）与终端迁出 `/usr/bin/ssh` 的并发地基。
final class SSHSessionPool {
    static let shared = SSHSessionPool()
    private init() {}

    /// 池键：同 host:port:user 的操作共享暖连接；连接相关设置（凭据/代理/算法）变了就是另一把键，
    /// 改完主机配置后不会再借到按旧配置建立的连接。
    private struct Key: Hashable { let host: String; let port: Int; let user: String; let config: String }
    // host/port/user 单列出来，供 closeHost 等按主机操作；config 用完整 poolKey 区分不同配置。

    private struct Pooled { let session: SSHSession; let idleSince: Date }

    private var idle: [Key: [Pooled]] = [:]
    private let lock = NSLock()
    /// 每主机最多保留的暖连接数（超出则归还时直接关闭，避免连接堆积）。
    private let maxIdlePerHost = 4
    /// 暖连接闲置超过此秒数即认为可能已被服务器断开，借用时丢弃重建（ControlPersist 旧值是 120s，这里更保守）。
    private let idleTTL: TimeInterval = 90

    private func key(_ c: SSHConnection) -> Key { Key(host: c.host, port: c.port, user: c.user, config: c.poolKey) }

    /// 借一条暖连接给短操作用：`body` 跑完自动归还以供复用；`body` 抛错（可能是断线）则弃用该连接、不污染池。
    /// `body` 在**调用线程同步执行并阻塞**（其内部 `SSHSession.exec` 自带串行队列，跨线程安全）——
    /// 务必在后台线程调用。
    /// 借到的是闲置过的暖连接且失败时，换一条新连接重试一次：NAT/防火墙可能早已悄悄回收了它。
    func withSession<T>(_ c: SSHConnection, _ body: (SSHSession) throws -> T) throws -> T {
        let (s, reused) = try borrow(c)
        do {
            let r = try body(s)
            giveBack(c, s)
            return r
        } catch {
            s.close()
            guard reused, (error as? SSHSession.SSHError)?.isChannelOpenFailure == true else { throw error }
            let fresh = try connect(c)
            do {
                let r = try body(fresh)
                giveBack(c, fresh)
                return r
            } catch {
                fresh.close()
                throw error
            }
        }
    }

    /// 手动借/还（供需要按结果决定“归还复用 vs 弃用”的调用方，如 RemoteFS.run：取消/超时过的连接须 discard，
    /// 因其 cancel 标志已置位且通道状态可能不洁）。借 → 跑 → 正常则 `recycle`、异常/取消则 `discard`。
    func take(_ c: SSHConnection) throws -> SSHSession { try borrow(c).session }
    /// 同 take，并告知是否为复用的暖连接（失败时可换新连接重试一次）。
    func takeReporting(_ c: SSHConnection) throws -> (session: SSHSession, reused: Bool) { try borrow(c) }
    func recycle(_ c: SSHConnection, _ s: SSHSession) { giveBack(c, s) }
    func discard(_ s: SSHSession) { s.close() }

    /// 取一条**独占**连接给长跑/流式操作用：不入池，调用方负责 `close()`。
    func dedicated(_ c: SSHConnection) throws -> SSHSession { try connect(c) }

    /// 关闭某主机的全部暖连接（等价旧 `ssh -O exit`：主机已无任何标签/视图时回收）。
    func closeHost(_ c: SSHConnection) {
        lock.lock(); let list = idle.removeValue(forKey: key(c)) ?? []; lock.unlock()
        for p in list { p.session.close() }
    }

    /// 关闭全部主机的暖连接（退出/全局重置时）。
    func closeAll() {
        lock.lock(); let all = idle.values.flatMap { $0 }; idle.removeAll(); lock.unlock()
        for p in all { p.session.close() }
    }

    // MARK: - 内部

    private func borrow(_ c: SSHConnection) throws -> (session: SSHSession, reused: Bool) {
        let k = key(c)
        let now = Date()
        while true {
            lock.lock()
            guard var list = idle[k], let p = list.popLast() else { lock.unlock(); break }
            idle[k] = list
            lock.unlock()
            if now.timeIntervalSince(p.idleSince) < idleTTL {
                return (p.session, true)    // 暖连接，直接复用
            }
            p.session.close()               // 太旧、可能已断 → 关掉，继续取下一条
        }
        return (try connect(c), false)      // 池空 → 新建
    }

    private func giveBack(_ c: SSHConnection, _ s: SSHSession) {
        let k = key(c)
        lock.lock()
        var list = idle[k] ?? []
        if list.count < maxIdlePerHost {
            list.append(Pooled(session: s, idleSince: Date()))
            idle[k] = list
            lock.unlock()
        } else {
            lock.unlock()
            s.close()                       // 池满 → 关掉多余连接
        }
    }

    private func connect(_ c: SSHConnection) throws -> SSHSession {
        try SSHSession.connect(c)
    }
}
