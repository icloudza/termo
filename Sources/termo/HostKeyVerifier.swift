import Foundation

/// 一台主机的密钥指纹信息（用于首次连接验证弹窗）。
struct HostKeyInfo {
    let host: String
    let port: Int
    let keyLine: String   // known_hosts 行（ssh-keyscan 输出），用于写入信任
    let sha256: String
    let md5: String
}

enum HostKeyDecision { case cancel, once, save }

/// 基于系统 ssh-keyscan / ssh-keygen 的主机密钥验证。
/// known_hosts 用「真实文件 + 本次会话临时文件」两份：信任并保存写真实文件，仅本次写临时文件（重启即失效）。
enum HostKeyVerifier {
    enum Preflight { case known, prompt(HostKeyInfo), scanFailed }

    static var realKnownHosts: String { NSHomeDirectory() + "/.ssh/known_hosts" }
    static var sessionKnownHosts: String { NSHomeDirectory() + "/.termo/session_known_hosts" }

    /// ssh 的 UserKnownHostsFile 值（两份文件，空格分隔）。
    static func userKnownHostsArg() -> String { "\(realKnownHosts) \(sessionKnownHosts)" }

    /// App 启动时清空会话临时文件（让「仅本次」在重启后重新验证）。
    static func resetSession() {
        ensureParentDir(sessionKnownHosts)
        try? Data().write(to: URL(fileURLWithPath: sessionKnownHosts))
    }

    /// 连接前预检（阻塞，建议在后台线程调用）。
    static func preflight(host: String, port: Int) -> Preflight {
        if isKnown(host: host, port: port) { return .known }
        if let info = scan(host: host, port: port) { return .prompt(info) }
        return .scanFailed
    }

    /// 写入信任：persist=true 写真实 known_hosts，false 写会话临时文件。
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

    private static func isKnown(host: String, port: Int) -> Bool {
        let spec = port == 22 ? host : "[\(host)]:\(port)"
        for file in [realKnownHosts, sessionKnownHosts] where FileManager.default.fileExists(atPath: file) {
            if run("/usr/bin/ssh-keygen", ["-F", spec, "-f", file]).code == 0 { return true }
        }
        return false
    }

    private static func scan(host: String, port: Int) -> HostKeyInfo? {
        let r = run("/usr/bin/ssh-keyscan", ["-p", String(port), "-T", "5", host])
        let lines = (String(data: r.out, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return nil }
        // 偏好最强算法：ed25519 > ecdsa > 其它
        let key = lines.first { $0.contains("ssh-ed25519") }
            ?? lines.first { $0.contains("ecdsa-") }
            ?? lines[0]

        let tmp = NSTemporaryDirectory() + "termo_hk_\(ProcessInfo.processInfo.globallyUniqueString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard (try? (key + "\n").write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }
        let sha = fingerprint(parse: run("/usr/bin/ssh-keygen", ["-lf", tmp]).out)
        let md5 = fingerprint(parse: run("/usr/bin/ssh-keygen", ["-E", "md5", "-lf", tmp]).out)
        guard !sha.isEmpty || !md5.isEmpty else { return nil }
        return HostKeyInfo(host: host, port: port, keyLine: key, sha256: sha, md5: md5)
    }

    private static func fingerprint(parse data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.split(separator: " ").first { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }
            .map(String.init) ?? ""
    }

    private static func ensureParentDir(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    private static func run(_ exe: String, _ args: [String]) -> (out: Data, code: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
        do { try p.run() } catch { return (Data(), -1) }
        let d = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (d, p.terminationStatus)
    }
}
