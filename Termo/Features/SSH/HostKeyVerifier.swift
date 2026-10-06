import Foundation

/// 按主机记住「优先协商哪种主机密钥算法」（取自 known_hosts 已记录的类型，进程内有效）。
/// 后台线程读写，故加锁。用户在高级设置里显式指定了主机密钥算法时不使用它。
enum HostKeyAlgoPreference {
    static let defaultOrder = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
                               "rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"]
    private static let lock = NSLock()
    private static var prefs: [String: String] = [:]

    static func get(host: String, port: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return prefs["\(host):\(port)"]
    }

    static func set(_ algos: String?, host: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        prefs["\(host):\(port)"] = algos
    }
}

/// 一台主机的密钥指纹信息（用于首次连接验证弹窗）。
struct HostKeyInfo {
    let host: String
    let port: Int
    let keyLine: String   // known_hosts 行（"<host|[host]:port> <keytype> <base64key>"），用于写入信任
    let sha256: String
    let md5: String
    var changed = false    // true=已有记录但密钥变了（疑似 MITM），弹窗需醒目警示
}

enum HostKeyDecision { case cancel, once, save }

/// 基于 libssh2 的主机密钥验证（替代旧的 ssh-keyscan / ssh-keygen 子进程）。
/// known_hosts 用「真实文件 + 本次会话临时文件」两份：信任并保存写真实文件，仅本次写临时文件（重启即失效）。
/// 实际连接的 MITM 强制由 `SSHSession.connect`（termo_ssh_open 认证前查 known_hosts、不匹配即拒）保证；
/// 本类负责连接前的「首次未知/已变更」交互式确认。
enum HostKeyVerifier {
    enum Preflight { case known, prompt(HostKeyInfo), changed(HostKeyInfo), scanFailed }

    static var realKnownHosts: String { NSHomeDirectory() + "/.ssh/known_hosts" }
    static var sessionKnownHosts: String { NSHomeDirectory() + "/.termo/session_known_hosts" }

    /// App 启动时清空会话临时文件（让「仅本次」在重启后重新验证）。
    static func resetSession() {
        ensureParentDir(sessionKnownHosts)
        try? Data().write(to: URL(fileURLWithPath: sessionKnownHosts))
    }

    /// 连接前预检（阻塞，建议在后台线程调用）：只握手取主机密钥、对照 known_hosts，不认证、不发密码。
    /// 与真实连接走同一代理、同一主机密钥算法偏好，扫到的密钥才与之后连接时看到的一致。
    static func preflight(conn: SSHConnection) -> Preflight {
        let host = conn.host, port = conn.port
        var scan = TermoHostKeyScan()
        conn.withSSHOptions { opts in
            termo_ssh_scan_hostkey(host, Int32(port), realKnownHosts, sessionKnownHosts, opts, &scan)
        }
        // 该主机在 known_hosts 里只记录了别的密钥类型（常见：OpenSSH 存的 ed25519，libssh2 默认先协商 ecdsa）：
        // 像 OpenSSH 一样改为优先协商已记录的类型再扫一次，能对上就无需用户确认。之后的连接都沿用这个偏好。
        if scan.status == 3, conn.hostKeyAlgos.isEmpty {
            let known = cstr(scan.known_algos)
            if !known.isEmpty {
                // 已记录的类型排最前，其余照常可用（服务器不再提供该类型时仍能协商，按「密钥已变更」提示）
                let first = known.split(separator: ",").map(String.init)
                let algos = (first + HostKeyAlgoPreference.defaultOrder.filter { !first.contains($0) }).joined(separator: ",")
                HostKeyAlgoPreference.set(algos, host: host, port: port)
                var retry = TermoHostKeyScan()
                conn.withSSHOptions { opts in
                    termo_ssh_scan_hostkey(host, Int32(port), realKnownHosts, sessionKnownHosts, opts, &retry)
                }
                if retry.status == 0 { return .known }
                if retry.status == -1 || retry.status == 3 { HostKeyAlgoPreference.set(nil, host: host, port: port) }
                if retry.status != -1 { scan = retry }
            }
        }
        switch scan.status {
        case 0:  return .known
        case 1:  return info(host, port, scan).map { .prompt($0) } ?? .scanFailed
        case 2, 3:   // 2=密钥不匹配；3=只记录过该主机的其它类型密钥（同样需要醒目确认）
            return info(host, port, scan).map { var i = $0; i.changed = true; return .changed(i) } ?? .scanFailed
        default: return .scanFailed   // -1：连接/握手失败，交给后续实际连接报错
        }
    }

    /// 写入信任：persist=true 写真实 known_hosts，false 写会话临时文件。追加单行（不重写用户文件）。
    static func trust(_ info: HostKeyInfo, persist: Bool) {
        let file = persist ? realKnownHosts : sessionKnownHosts
        ensureParentDir(file)
        let line = info.keyLine.hasSuffix("\n") ? info.keyLine : info.keyLine + "\n"
        if let fh = FileHandle(forWritingAtPath: file) {
            fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
        } else {
            try? line.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 内部

    private static func info(_ host: String, _ port: Int, _ scan: TermoHostKeyScan) -> HostKeyInfo? {
        let line = cstr(scan.line)
        guard !line.isEmpty else { return nil }
        return HostKeyInfo(host: host, port: port, keyLine: line,
                           sha256: cstr(scan.sha256), md5: cstr(scan.md5))
    }

    /// C 定长 char 数组（导入为 Swift 元组）→ String。
    private static func cstr<T>(_ tuple: T) -> String {
        var t = tuple
        return withUnsafeBytes(of: &t) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private static func ensureParentDir(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
}
