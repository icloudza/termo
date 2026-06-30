import Foundation

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

    /// ssh 的 UserKnownHostsFile 值（两份文件，空格分隔）。供尚未迁移的 ssh 子进程路径使用。
    static func userKnownHostsArg() -> String { "\(realKnownHosts) \(sessionKnownHosts)" }

    /// App 启动时清空会话临时文件（让「仅本次」在重启后重新验证）。
    static func resetSession() {
        ensureParentDir(sessionKnownHosts)
        try? Data().write(to: URL(fileURLWithPath: sessionKnownHosts))
    }

    /// 连接前预检（阻塞，建议在后台线程调用）：只握手取主机密钥、对照 known_hosts，不认证、不发密码。
    static func preflight(host: String, port: Int) -> Preflight {
        var scan = TermoHostKeyScan()
        termo_ssh_scan_hostkey(host, Int32(port), realKnownHosts, sessionKnownHosts, &scan)
        switch scan.status {
        case 0:  return .known
        case 1:  return info(host, port, scan).map { .prompt($0) } ?? .scanFailed
        case 2:  return info(host, port, scan).map { var i = $0; i.changed = true; return .changed(i) } ?? .scanFailed
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
