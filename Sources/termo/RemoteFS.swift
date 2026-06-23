import Foundation

struct RemoteFSError: Error { let message: String }

/// 文件浏览/树的加载状态。
enum LoadPhase: Equatable { case loading, loaded, error(String) }

/// 一个远程目录条目。
struct RemoteFile: Identifiable, Hashable {
    enum Kind { case directory, file, symlink, other }
    let name: String
    let path: String          // 绝对路径
    let kind: Kind
    let size: Int64
    let modified: Date?
    var id: String { path }
    var isDir: Bool { kind == .directory }
}

/// 基于系统 ssh 的远程文件系统操作（复用 SSHConnection 的全部连接配置 + askpass）。
/// 每次操作一个短命 ssh 进程，靠 ControlMaster 复用主连接，认证只触发一次。
final class RemoteFS {
    private let ssh: SSHConnection
    init(_ ssh: SSHConnection) { self.ssh = ssh }

    struct OpResult { let data: Data; let stderr: Data; let code: Int32 }

    /// 执行一条远端命令（经登录 shell）。流式抽干管道，避免大输出时缓冲区填满导致死锁。
    func run(_ remoteCommand: String, timeout: Double = 20) async -> OpResult {
        ensureControlDir()
        return await withCheckedContinuation { (cont: CheckedContinuation<OpResult, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = ssh.sshArguments(multiplex: true) + ["-o", "BatchMode=no", remoteCommand]
            var env = ProcessInfo.processInfo.environment
            if ssh.needsAskpass, let ap = SSHAskpass.envVars(password: ssh.password) {
                for (k, v) in ap { env[k] = v }
            }
            proc.environment = env

            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            var outData = Data(), errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.notify(queue: .global()) {
                proc.waitUntilExit()
                cont.resume(returning: OpResult(data: outData, stderr: errData, code: proc.terminationStatus))
            }

            do {
                try proc.run()
            } catch {
                cont.resume(returning: OpResult(data: Data(), stderr: Data(), code: -1))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning { proc.terminate() }
            }
        }
    }

    /// 断开该主机的 ControlMaster 复用主连接（文件浏览的底层连接）。
    func closeMaster() {
        ensureControlDir()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ssh.sshArguments(multiplex: true) + ["-O", "exit"]
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
    }

    /// 登录用户的家目录绝对路径。
    func home() async -> String {
        let r = await run("cd && pwd")
        let s = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "/" : s
    }

    /// 列出某绝对路径下的条目。优先 GNU `find -printf`（含大小/时间），失败回退到 `ls -1Ap`（仅名称/类型）。
    func list(_ path: String) async -> Result<[RemoteFile], RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        // 主路径：GNU find，NUL 分隔，字段 = 类型\t字节\t mtime秒 \t basename
        let gnu = "P=$(printf %s '\(b64)'|base64 -d); " +
            "find \"$P\" -maxdepth 1 -mindepth 1 -printf '%y\\t%s\\t%Ts\\t%f\\0' 2>/dev/null"
        var r = await run(gnu)
        if r.code == 0, !r.data.isEmpty {
            return .success(sorted(parseFind(r.data, base: path)))
        }
        if r.code == 0, r.data.isEmpty {
            // 可能是空目录，也可能 find 不支持；用 ls 兜底区分
        }
        // 回退：ls -1Ap（兼容 BSD），仅名称 + 目录斜杠
        let fb = "P=$(printf %s '\(b64)'|base64 -d); ls -1Ap -- \"$P\""
        r = await run(fb)
        if r.code == 0 {
            return .success(sorted(parseLs(r.data, base: path)))
        }
        let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(RemoteFSError(message: err.isEmpty ? "无法列出目录（退出码 \(r.code)）" : err))
    }

    // MARK: - 解析

    private func parseFind(_ data: Data, base: String) -> [RemoteFile] {
        var out: [RemoteFile] = []
        for rec in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let s = String(data: Data(rec), encoding: .utf8) else { continue }
            let p = s.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard p.count == 4 else { continue }
            let name = String(p[3])
            let kind: RemoteFile.Kind
            switch p[0] {
            case "d": kind = .directory
            case "f": kind = .file
            case "l": kind = .symlink
            default: kind = .other
            }
            let size = Int64(p[1]) ?? 0
            let mtime = Double(p[2]).map { Date(timeIntervalSince1970: $0) }
            out.append(RemoteFile(name: name, path: join(base, name), kind: kind, size: size, modified: mtime))
        }
        return out
    }

    private func parseLs(_ data: Data, base: String) -> [RemoteFile] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [RemoteFile] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var name = String(raw)
            var kind: RemoteFile.Kind = .file
            if name.hasSuffix("/") { name.removeLast(); kind = .directory }
            else if name.hasSuffix("@") { name.removeLast(); kind = .symlink }
            if name.isEmpty || name == "." || name == ".." { continue }
            out.append(RemoteFile(name: name, path: join(base, name), kind: kind, size: 0, modified: nil))
        }
        return out
    }

    private func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }   // 目录在前
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    private func ensureControlDir() {
        let dir = NSHomeDirectory() + "/.termo/cm"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
}

/// 把字节数格式化为人类可读（用于文件大小显示）。
func humanSize(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "—" }
    let units = ["B", "K", "M", "G", "T"]
    var v = Double(bytes); var i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(bytes) B" : String(format: "%.1f%@", v, units[i])
}
