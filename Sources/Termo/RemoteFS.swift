import Foundation

struct RemoteFSError: Error {
    let message: String
    /// 保存时检测到文件已被其他程序/会话修改（乐观锁冲突）→ 上层弹窗让用户选覆盖/重载/取消。
    var isConflict: Bool = false
}

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
    /// `stdin` 非空时写入子进程标准输入（用于写文件等大数据下行）。
    func run(_ remoteCommand: String, stdin: Data? = nil, timeout: Double = 20) async -> OpResult {
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
            let inPipe: Pipe? = stdin != nil ? Pipe() : nil
            if let inPipe { proc.standardInput = inPipe }

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
            // 在独立线程写入 stdin（大数据需分块，避免与 ssh 输出形成管道死锁）
            if let inPipe, let stdin {
                DispatchQueue.global().async {
                    let fh = inPipe.fileHandleForWriting
                    fh.write(stdin)
                    try? fh.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning { proc.terminate() }
            }
        }
    }

    // MARK: - 文件读写

    /// 读取远端文件（base64 安全传输，二进制安全）。最多读取 `limit` 字节。
    /// 返回内容 + **版本令牌**（`mtime:size` 字符串，乐观锁用；stat 不可用时为 nil）。输出首行=版本，其余=base64。
    func read(_ path: String, limit: Int) async -> Result<(data: Data, version: String?), RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        // head -c 限制读取量；base64 编码避免控制字符被 shell/传输破坏
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); " +
            "if [ ! -e \"$P\" ]; then echo __TERMO_NOENT__ >&2; exit 2; fi; " +
            "if [ -d \"$P\" ]; then echo __TERMO_ISDIR__ >&2; exit 3; fi; " +
            "echo \"__TERMO_VER__:$(stat -c '%Y:%s' \"$P\" 2>/dev/null || stat -f '%m:%z' \"$P\" 2>/dev/null)\"; " +
            "head -c \(limit) \"$P\" | base64"
        let r = await run(cmd, timeout: 40)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg: String
            if err.contains("__TERMO_NOENT__") { msg = "文件不存在" }
            else if err.contains("__TERMO_ISDIR__") { msg = "这是一个目录" }
            else if err.contains("Permission denied") || err.contains("permission") { msg = "没有读取权限" }
            else { msg = err.isEmpty ? "无法读取文件（退出码 \(r.code)）" : err }
            return .failure(RemoteFSError(message: msg))
        }
        // 拆首行（版本）与正文（base64）
        var version: String? = nil
        var body = r.data
        if let nl = r.data.firstIndex(of: 0x0A) {
            let firstLine = String(data: r.data[r.data.startIndex..<nl], encoding: .utf8) ?? ""
            if firstLine.hasPrefix("__TERMO_VER__:") {
                let v = String(firstLine.dropFirst("__TERMO_VER__:".count))
                version = v.isEmpty ? nil : v
                body = Data(r.data[r.data.index(after: nl)...])
            }
        }
        guard let decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else {
            return .failure(RemoteFSError(message: "内容解码失败"))
        }
        return .success((decoded, version))
    }

    /// 写入远端文件（乐观并发控制）。内容经 base64 由 stdin 下行；远端先写同目录临时文件：
    /// - `expectedVersion` 非空时，落地前比对当前 `mtime:size`，**不一致即冲突**（被他人改过）→ 退出码 9，不覆盖。
    /// - 落地优先 `mv` **原子替换**（先 `chmod/chown --reference` 继承原文件权限+属主）；
    ///   `mv`/继承不可用时（如目录不可写、非 GNU、非 root）回退 `cat >` 原地覆盖（保 inode/属主、零权限要求）。
    /// 成功返回**新版本令牌** `mtime:size`，上层据此更新基准。
    func write(_ path: String, data: Data, expectedVersion: String?) async -> Result<String, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let payload = Data(data.base64EncodedString().utf8)
        let exp = expectedVersion ?? ""          // 我方 stat 得到的 "mtime:size"，纯数字+冒号，内联安全
        let stat = "stat -c '%Y:%s' \"$P\" 2>/dev/null || stat -f '%m:%z' \"$P\" 2>/dev/null"
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); EXP='\(exp)'; T=\"$P.termo-tmp.$$\"; " +
            "if base64 -d > \"$T\" 2>/dev/null; then " +
            "  if [ -e \"$P\" ]; then " +
            "    CUR=$(\(stat)); " +
            "    if [ -n \"$EXP\" ] && [ \"$CUR\" != \"$EXP\" ]; then rm -f \"$T\"; echo __TERMO_CONFLICT__ >&2; exit 9; fi; " +
            "    if chmod --reference=\"$P\" \"$T\" 2>/dev/null && chown --reference=\"$P\" \"$T\" 2>/dev/null && mv -f \"$T\" \"$P\" 2>/dev/null; then \(stat); " +
            "    elif cat \"$T\" > \"$P\" 2>/dev/null; then rm -f \"$T\"; \(stat); " +
            "    else rm -f \"$T\"; echo __TERMO_WRITEFAIL__ >&2; exit 7; fi; " +
            "  else " +
            "    if mv -f \"$T\" \"$P\" 2>/dev/null; then \(stat); else rm -f \"$T\"; echo __TERMO_WRITEFAIL__ >&2; exit 7; fi; " +
            "  fi; " +
            "else rm -f \"$T\" 2>/dev/null; echo __TERMO_TMPFAIL__ >&2; exit 8; fi"
        let r = await run(cmd, stdin: payload, timeout: 60)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if err.contains("__TERMO_CONFLICT__") {
                return .failure(RemoteFSError(message: "文件已被其他程序或会话修改", isConflict: true))
            }
            let msg: String
            if err.contains("__TERMO_WRITEFAIL__") || err.contains("Permission denied") { msg = "没有写入权限" }
            else if err.contains("__TERMO_TMPFAIL__") { msg = "无法在目标目录创建临时文件" }
            else { msg = err.isEmpty ? "保存失败（退出码 \(r.code)）" : err }
            return .failure(RemoteFSError(message: msg))
        }
        let newVer = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .success(newVer)
    }

    // MARK: - 文件管理（删除 / 重命名 / 权限）

    /// 删除文件或目录（目录用 `rm -rf`）。
    func delete(_ path: String, isDir: Bool) async -> Result<Void, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let rm = isDir ? "rm -rf" : "rm -f"
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); \(rm) -- \"$P\""
        let r = await run(cmd)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = err.localizedCaseInsensitiveContains("permission") ? "没有删除权限"
                : (err.isEmpty ? "删除失败（退出码 \(r.code)）" : err)
            return .failure(RemoteFSError(message: msg))
        }
        return .success(())
    }

    /// 重命名 / 移动（同目录改名即重命名）。目标已存在则拒绝，避免覆盖。
    func rename(_ from: String, to: String) async -> Result<Void, RemoteFSError> {
        let bf = Data(from.utf8).base64EncodedString()
        let bt = Data(to.utf8).base64EncodedString()
        let cmd = "F=$(printf %s '\(bf)'|base64 -d); T=$(printf %s '\(bt)'|base64 -d); " +
            "if [ -e \"$T\" ]; then echo __TERMO_EXISTS__ >&2; exit 9; fi; mv -- \"$F\" \"$T\""
        let r = await run(cmd)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg: String
            if err.contains("__TERMO_EXISTS__") { msg = "目标名称已存在" }
            else if err.localizedCaseInsensitiveContains("permission") { msg = "没有重命名权限" }
            else { msg = err.isEmpty ? "重命名失败（退出码 \(r.code)）" : err }
            return .failure(RemoteFSError(message: msg))
        }
        return .success(())
    }

    /// 修改权限（mode = 八进制字符串，如 "755"）。
    func chmod(_ path: String, mode: String) async -> Result<Void, RemoteFSError> {
        // mode 由调用方保证为 3–4 位八进制数字，内联安全
        let b64 = Data(path.utf8).base64EncodedString()
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); chmod \(mode) -- \"$P\""
        let r = await run(cmd)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = err.localizedCaseInsensitiveContains("permission") ? "没有修改权限的权限"
                : (err.isEmpty ? "修改权限失败（退出码 \(r.code)）" : err)
            return .failure(RemoteFSError(message: msg))
        }
        return .success(())
    }

    /// 路径是否存在（区分"远端已删除"与"瞬时失败/无权限"）。
    func exists(_ path: String) async -> Bool {
        let b64 = Data(path.utf8).base64EncodedString()
        let r = await run("P=$(printf %s '\(b64)'|base64 -d); [ -e \"$P\" ] && echo __Y__ || echo __N__")
        return (String(data: r.data, encoding: .utf8) ?? "").contains("__Y__")
    }

    /// 取当前权限（八进制三位，如 0o755 的十进制值）。GNU `stat -c %a` / BSD `stat -f %Lp`。
    func statPerms(_ path: String) async -> Result<Int, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); stat -c '%a' \"$P\" 2>/dev/null || stat -f '%Lp' \"$P\" 2>/dev/null"
        let r = await run(cmd)
        let s = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard r.code == 0, let v = Int(s, radix: 8) else {
            return .failure(RemoteFSError(message: "无法读取权限"))
        }
        return .success(v)
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
