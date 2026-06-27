import Foundation

struct RemoteFSError: Error {
    let message: String
    /// 保存时检测到文件已被其他程序/会话修改（乐观锁冲突）→ 上层弹窗让用户选覆盖/重载/取消。
    var isConflict: Bool = false
}

// MARK: - 上传 v2 传输层类型

/// 传输信号（单一原子状态）。
enum UploadSignal { case run, cancel, pause }

/// 单文件传输控制盒（跨线程，锁保护）：承载控制信号与已发送字节（后者仅供 UI 进度显示）。
final class UploadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _signal: UploadSignal = .run
    private var _sent: Int64 = 0
    func set(_ s: UploadSignal) { lock.lock(); _signal = s; lock.unlock() }
    var signal: UploadSignal { lock.lock(); defer { lock.unlock() }; return _signal }
    func setSent(_ v: Int64) { lock.lock(); _sent = v; lock.unlock() }
    var sent: Int64 { lock.lock(); defer { lock.unlock() }; return _sent }
}

/// 命令取消句柄：持有运行中的 ssh 子进程，cancel() 终止它——远端命令随通道关闭收到 SIGHUP 而结束。
/// 用于让「正在删除」等可能较慢的命令支持用户中途取消。线程安全。
final class CommandHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    private var cancelled = false

    /// 绑定已启动的子进程；若在绑定前已被取消，立即终止它。
    func bind(_ p: Process) {
        lock.lock(); let c = cancelled; if !c { proc = p }; lock.unlock()
        if c, p.isRunning { p.terminate() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let p = proc; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// 单文件传输结果。续传偏移**不在这里返回**——须由上层在传输结束后重新 stat 远端 .part 取得
/// （本地"已发送"含管道缓冲，会高估实际落地字节，直接当偏移会造成数据空洞，见审查 R1）。
enum UploadOutcome: Equatable { case completed, cancelled, paused, failed(String) }

/// 上传前探测：远端 .part 半截大小、正式文件是否存在/大小。
struct UploadProbe { let partSize: Int64; let finalExists: Bool; let finalSize: Int64 }

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

/// 基于系统 ssh 的远程文件系统操作（复用 SSHConnection 的全部连接配置与 askpass）。
/// 每次操作起一个短命 ssh 进程，靠 ControlMaster 复用主连接，认证只触发一次。
final class RemoteFS {
    private let ssh: SSHConnection
    init(_ ssh: SSHConnection) { self.ssh = ssh }

    // MARK: - SFTP 会话（懒建，串行；传输级失败后本会话粘性回退到 shell-exec）
    private var _sftp: SFTPSession?
    private let sftpLock = NSLock()
    private var sftpUsable = true

    private var isSftpUsable: Bool { sftpLock.lock(); defer { sftpLock.unlock() }; return sftpUsable }
    private func session() -> SFTPSession {
        sftpLock.lock(); defer { sftpLock.unlock() }
        if let s = _sftp { return s }
        let s = SFTPSession(ssh); _sftp = s; return s
    }
    /// 标记 SFTP 不可用 → 后续走 shell-exec；关掉子进程。
    private func markSftpDown() {
        sftpLock.lock(); let s = _sftp; sftpUsable = false; _sftp = nil; sftpLock.unlock()
        Task { await s?.shutdown() }
    }

    /// 网络切换后重置本实例的 SFTP 会话：关掉旧会话、解除粘性 shell 回退，使下次操作自动重建 SFTP。
    /// stale ControlMaster 的清理按主机统一在上层做一次（见 AppModel.reconnectFileViewsAfterNetworkChange），
    /// 不在此每实例重复 closeMaster，避免同一主机被多次 ssh -O exit。
    func resetForReconnect() {
        sftpLock.lock(); let s = _sftp; _sftp = nil; sftpUsable = true; sftpLock.unlock()
        Task { await s?.shutdown() }
    }
    /// 由 SFTP 权限位判文件类型（缺权限 → .other，审查 R3）。
    private func kindFromMode(_ perm: UInt32?) -> RemoteFile.Kind {
        guard let m = perm else { return .other }
        switch m & 0o170000 {
        case 0o040000: return .directory
        case 0o120000: return .symlink
        case 0o100000: return .file
        default:       return .other
        }
    }

    struct OpResult { let data: Data; let stderr: Data; let code: Int32 }

    /// 执行一条远端命令（经登录 shell）。流式抽干管道，避免大输出时缓冲区填满导致死锁。
    /// `stdin` 非空时写入子进程标准输入（用于写文件等大数据下行）。
    func run(_ remoteCommand: String, stdin: Data? = nil, timeout: Double = 20,
             handle: CommandHandle? = nil) async -> OpResult {
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
            handle?.bind(proc)   // 绑定取消句柄：用户取消时终止此子进程
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

    // MARK: - 上传（.part 落地 + 续写 + 取消）

    /// SFTP STAT 包装：文件不存在 → nil；其它错误（含 transport）抛出。
    private func sftpStatOrNil(_ path: String) async throws -> SFTPAttrs? {
        do { return try await session().stat(path) }
        catch let e as SFTPError where e.isNoSuchFile { return nil }
    }

    /// 探测远端：.part 半截大小（续传偏移）、正式文件是否存在/大小（同名询问）。
    func probeUpload(remotePath: String) async -> UploadProbe {
        if isSftpUsable {
            do {
                let part = try await sftpStatOrNil(remotePath + ".part")
                let final = try await sftpStatOrNil(remotePath)
                return UploadProbe(partSize: Int64(part?.size ?? 0),
                                   finalExists: final != nil,
                                   finalSize: Int64(final?.size ?? 0))
            }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch { return UploadProbe(partSize: 0, finalExists: false, finalSize: 0) }
        }
        return await probeUploadViaShell(remotePath: remotePath)
    }
    private func probeUploadViaShell(remotePath: String) async -> UploadProbe {
        let b64 = Data(remotePath.utf8).base64EncodedString()
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); T=\"$P.part\"; ps=-1; fs=-1; fe=0; " +
            "if [ -e \"$T\" ]; then ps=$(stat -c %s \"$T\" 2>/dev/null || stat -f %z \"$T\" 2>/dev/null); fi; " +
            "if [ -e \"$P\" ]; then fe=1; fs=$(stat -c %s \"$P\" 2>/dev/null || stat -f %z \"$P\" 2>/dev/null); fi; " +
            "echo \"$ps $fs $fe\""
        let r = await run(cmd, timeout: 20)
        let parts = (String(data: r.data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").map { Int64($0) ?? -1 }
        guard r.code == 0, parts.count >= 3 else {
            return UploadProbe(partSize: 0, finalExists: false, finalSize: 0)
        }
        return UploadProbe(partSize: max(0, parts[0]), finalExists: parts[2] == 1, finalSize: max(0, parts[1]))
    }

    /// 把 .part 原子落地为正式文件（覆盖已有时先继承其权限，再原子改名）。整文件传完后调。
    func finalizeUpload(remotePath: String) async -> Result<Void, RemoteFSError> {
        if isSftpUsable {
            do { try await sftpFinalize(remotePath); return .success(()) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError { return .failure(RemoteFSError(message: e.message)) }
            catch { return .failure(RemoteFSError(message: "落地失败")) }
        }
        return await finalizeUploadViaShell(remotePath: remotePath)
    }
    private func sftpFinalize(_ remotePath: String) async throws {
        let s = session()
        let part = remotePath + ".part"
        if let perm = (try await sftpStatOrNil(remotePath))?.permissions {
            try? await s.setPermissions(part, perm)        // 继承原权限（best-effort）
        }
        if await s.supportsPosixRename {
            try await s.posixRename(from: part, to: remotePath)    // 原子覆盖（审查 R7）
        } else {
            do { try await s.rename(from: part, to: remotePath) }
            catch { try? await s.remove(remotePath); try await s.rename(from: part, to: remotePath) }
        }
    }
    private func finalizeUploadViaShell(remotePath: String) async -> Result<Void, RemoteFSError> {
        let b64 = Data(remotePath.utf8).base64EncodedString()
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); T=\"$P.part\"; " +
            "if [ -e \"$P\" ]; then chmod --reference=\"$P\" \"$T\" 2>/dev/null || " +
            "chmod \"$(stat -f %Lp \"$P\" 2>/dev/null)\" \"$T\" 2>/dev/null; fi; " +
            "mv -f \"$T\" \"$P\""
        let r = await run(cmd, timeout: 30)
        return r.code == 0 ? .success(()) : .failure(RemoteFSError(message: "落地失败（退出码 \(r.code)）"))
    }

    /// 删除远端 .part（取消并放弃时）。best-effort，失败靠下次 probe 自愈。
    func cleanupPart(remotePath: String) async {
        if isSftpUsable {
            do { try await session().remove(remotePath + ".part"); return }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch { return }
        }
        let b64 = Data(remotePath.utf8).base64EncodedString()
        _ = await run("P=$(printf %s '\(b64)'|base64 -d); rm -f \"$P.part\"", timeout: 15)
    }

    // MARK: - 新建 / 下载

    /// 新建目录（已存在则失败）。SFTP 优先，回退 shell。
    func mkdir(_ path: String) async -> Result<Void, RemoteFSError> {
        if isSftpUsable {
            do { try await session().mkdir(path); return .success(()) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isPermission ? "没有创建权限" : e.message))
            }
            catch { return .failure(RemoteFSError(message: "新建文件夹失败")) }
        }
        let b64 = Data(path.utf8).base64EncodedString()
        let r = await run("P=$(printf %s '\(b64)'|base64 -d); mkdir -- \"$P\"")
        return r.code == 0 ? .success(()) : .failure(Self.shellErr(r, "新建文件夹失败"))
    }

    /// 新建空文件（noclobber 防覆盖已有）。
    func createFile(_ path: String) async -> Result<Void, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let r = await run("P=$(printf %s '\(b64)'|base64 -d); set -C; : > \"$P\"")
        return r.code == 0 ? .success(()) : .failure(RemoteFSError(message: "新建文件失败（可能已存在或无权限）"))
    }

    /// 下载远端文件到本地：SFTP 流式分块读 → 写本地，避免整文件进内存；经 control 上报进度、响应取消。
    /// 须经独立 RemoteFS 实例调用（自带 SFTP 通道，不阻塞文件浏览所用的会话）。
    /// 下载到本地文件。startOffset>0 表示续传：从本地已有半截续写、远端从该偏移继续读（暂停恢复用）。
    func download(_ remotePath: String, to localURL: URL, startOffset: Int64 = 0, control: UploadControl) async -> UploadOutcome {
        guard isSftpUsable else { return .failed("需要 SFTP 连接") }
        do {
            let handle = try await session().open(remotePath, pflags: SFTPFlag.READ)
            let fh: FileHandle
            if startOffset > 0, FileManager.default.fileExists(atPath: localURL.path) {
                // 续传：追加到本地半截。打不开则报错（绝不退回截断重建，否则会丢掉已下载部分造成空洞）。
                guard let h = try? FileHandle(forWritingTo: localURL) else {
                    await session().closeHandle(handle); return .failed("无法写入本地文件")
                }
                try? h.seekToEnd()
                fh = h
            } else {
                FileManager.default.createFile(atPath: localURL.path, contents: nil)
                guard let h = try? FileHandle(forWritingTo: localURL) else {
                    await session().closeHandle(handle); return .failed("无法写入本地文件")
                }
                fh = h
            }
            var offset: UInt64 = startOffset > 0 ? UInt64(startOffset) : 0
            control.setSent(Int64(offset))
            while true {
                let sig = control.signal
                if sig == .cancel { try? fh.close(); await session().closeHandle(handle); return .cancelled }
                if sig == .pause { try? fh.close(); await session().closeHandle(handle); return .paused }  // 保留本地半截
                guard let chunk = try await session().read(handle, offset: offset, length: 32768),
                      !chunk.isEmpty else { break }
                fh.write(chunk)
                offset += UInt64(chunk.count)
                control.setSent(Int64(offset))
            }
            try? fh.close()
            await session().closeHandle(handle)
            return .completed
        } catch let e as SFTPError where e.isTransport {
            markSftpDown(); return .failed("连接中断")
        } catch let e as SFTPError {
            return .failed(e.isPermission ? "没有读取权限" : e.message)
        } catch {
            return .failed("下载失败")
        }
    }

    private static func shellErr(_ r: OpResult, _ fallback: String) -> RemoteFSError {
        let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RemoteFSError(message: err.isEmpty ? fallback : err)
    }

    /// 上传单个本地文件到 "$remotePath.part"。SFTP 走原生偏移写（续传天然干净）；否则回退单管道 cat。
    func upload(localURL: URL, toRemote remotePath: String,
                startOffset: Int64, control: UploadControl) async -> UploadOutcome {
        if isSftpUsable {
            return await sftpUpload(localURL: localURL, toRemote: remotePath, startOffset: startOffset, control: control)
        }
        return await uploadViaShell(localURL: localURL, toRemote: remotePath, startOffset: startOffset, control: control)
    }

    /// SFTP 上传：OPEN(.part) → FSTAT 收敛偏移防空洞（R4）→ 32K WRITE 循环 → CLOSE。
    /// 自己处理错误（不抛）：transport → markSftpDown + .failed（上层重试时会改走 shell 并重 probe 偏移）。
    private func sftpUpload(localURL: URL, toRemote remotePath: String,
                           startOffset: Int64, control: UploadControl) async -> UploadOutcome {
        let s = session()
        let part = remotePath + ".part"
        let pflags = startOffset > 0 ? (SFTPFlag.WRITE | SFTPFlag.CREAT)
                                     : (SFTPFlag.WRITE | SFTPFlag.CREAT | SFTPFlag.TRUNC)
        do {
            let h = try await s.open(part, pflags: pflags)
            var off: UInt64 = 0
            if startOffset > 0 {
                let real = (try await s.fstat(h)).size ?? 0
                off = min(UInt64(startOffset), real)      // 续传偏移以远端 .part 实际大小为准（R4）
            }
            guard let input = try? FileHandle(forReadingFrom: localURL) else {
                await s.closeHandle(h); return .failed("无法读取本地文件")
            }
            if off > 0 { try? input.seek(toOffset: off) }
            var sent = Int64(off)
            control.setSent(sent)
            while true {
                let sig = control.signal
                if sig == .cancel { try? input.close(); await s.closeHandle(h); return .cancelled }
                if sig == .pause { try? input.close(); await s.closeHandle(h); return .paused }  // 保留远端 .part
                let chunk: Data
                do {
                    guard let c = try input.read(upToCount: 32 * 1024), !c.isEmpty else { break }   // EOF
                    chunk = c
                } catch { try? input.close(); await s.closeHandle(h); return .failed("读取本地文件出错") }
                do { try await s.write(h, offset: UInt64(sent), data: chunk) }
                catch let e as SFTPError where e.isTransport {
                    try? input.close(); await s.closeHandle(h); markSftpDown(); return .failed("连接中断")
                } catch let e as SFTPError {
                    try? input.close(); await s.closeHandle(h)
                    return .failed(e.isPermission ? "没有写入权限" : e.message)
                }
                sent += Int64(chunk.count)
                control.setSent(sent)
            }
            try? input.close()
            await s.closeHandle(h)
            return .completed
        } catch let e as SFTPError where e.isTransport {
            markSftpDown(); return .failed("连接中断")
        } catch let e as SFTPError {
            return .failed(e.isPermission ? "没有写入权限" : e.message)
        } catch {
            return .failed("上传失败")
        }
    }

    /// 单管道回退：喂 ssh stdin（cat > / cat >>），与 v1 同一条可靠路径。
    private func uploadViaShell(localURL: URL, toRemote remotePath: String,
                startOffset: Int64,
                control: UploadControl) async -> UploadOutcome {
        ensureControlDir()
        let b64 = Data(remotePath.utf8).base64EncodedString()
        let redir = startOffset > 0 ? ">>" : ">"
        let remoteCmd = "P=$(printf %s '\(b64)'|base64 -d); T=\"$P.part\"; cat \(redir) \"$T\""

        return await withCheckedContinuation { (cont: CheckedContinuation<UploadOutcome, Never>) in
            let sshProc = Process()
            sshProc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            sshProc.arguments = self.ssh.sshArguments(multiplex: true)
                + ["-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4",
                   "-o", "BatchMode=no", remoteCmd]
            var env = ProcessInfo.processInfo.environment
            if self.ssh.needsAskpass, let ap = SSHAskpass.envVars(password: self.ssh.password) {
                for (k, v) in ap { env[k] = v }
            }
            sshProc.environment = env

            let errPipe = Pipe(), sshIn = Pipe()
            sshProc.standardOutput = FileHandle.nullDevice
            sshProc.standardError = errPipe
            sshProc.standardInput = sshIn
            let feed = sshIn.fileHandleForWriting

            let stopLock = NSLock()
            var cancelled = false
            var paused = false
            var hitEOF = false
            var feederError: String? = nil

            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.notify(queue: .global()) {
                sshProc.waitUntilExit()
                stopLock.lock()
                let c = cancelled; let p = paused; let eof = hitEOF; let ferr = feederError
                stopLock.unlock()
                if c { cont.resume(returning: .cancelled); return }
                if p { cont.resume(returning: .paused); return }   // 保留远端 .part 供续传
                if let ferr { cont.resume(returning: .failed(ferr)); return }
                if eof && sshProc.terminationStatus == 0 {
                    cont.resume(returning: .completed)
                } else {
                    let e = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(returning: .failed(e.isEmpty
                        ? "上传中断（ssh \(sshProc.terminationStatus)）" : e))
                }
            }

            do { try sshProc.run() }
            catch { cont.resume(returning: .failed("无法启动 ssh")); return }

            // 取消看门狗：喂入循环结束后若卡在「等 ssh 退出」，取消也能立刻杀掉 ssh（否则取消无效）。
            DispatchQueue.global().async {
                while sshProc.isRunning {
                    let sig = control.signal
                    if sig == .cancel || sig == .pause {
                        stopLock.lock(); if sig == .cancel { cancelled = true } else { paused = true }; stopLock.unlock()
                        sshProc.terminate(); break
                    }
                    Thread.sleep(forTimeInterval: 0.15)
                }
            }

            // 后台喂入：本地文件(seek 到 startOffset) → ssh stdin
            DispatchQueue.global().async {
                guard let input = try? FileHandle(forReadingFrom: localURL) else {
                    stopLock.lock(); feederError = "无法读取本地文件"; stopLock.unlock()
                    try? feed.close()
                    if sshProc.isRunning { sshProc.terminate() }
                    return
                }
                if startOffset > 0 { try? input.seek(toOffset: UInt64(startOffset)) }
                var sent = startOffset
                control.setSent(sent)
                while true {
                    let sig = control.signal
                    if sig == .cancel || sig == .pause {
                        stopLock.lock(); if sig == .cancel { cancelled = true } else { paused = true }; stopLock.unlock(); break
                    }
                    let chunk: Data
                    do {
                        guard let c = try input.read(upToCount: 256 * 1024), !c.isEmpty else {
                            stopLock.lock(); hitEOF = true; stopLock.unlock(); break
                        }
                        chunk = c
                    } catch {
                        stopLock.lock(); feederError = "读取本地文件出错"; stopLock.unlock(); break
                    }
                    do { try feed.write(contentsOf: chunk) }
                    catch {
                        stopLock.lock(); if !cancelled { feederError = "连接中断" }; stopLock.unlock(); break
                    }
                    sent += Int64(chunk.count)
                    control.setSent(sent)
                }
                try? input.close()
                try? feed.close()   // 关 ssh stdin → 远端 cat 收 EOF 落地 → ssh 退出
                let sig = control.signal
                if (sig == .cancel || sig == .pause), sshProc.isRunning { sshProc.terminate() }
            }
        }
    }

    // MARK: - 文件读写

    func read(_ path: String, limit: Int) async -> Result<(data: Data, version: String?), RemoteFSError> {
        if isSftpUsable {
            do { return .success(try await sftpRead(path, limit: limit)) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isNoSuchFile ? "文件不存在"
                    : (e.isPermission ? "没有读取权限" : e.message)))
            }
            catch { return .failure(RemoteFSError(message: "无法读取文件")) }
        }
        return await readViaShell(path, limit: limit)
    }

    private func sftpRead(_ path: String, limit: Int) async throws -> (data: Data, version: String?) {
        let s = session()
        let h = try await s.open(path, pflags: SFTPFlag.READ)
        do {
            let version = (try await s.fstat(h)).versionToken   // "mtime:size"，用 FSTAT 跟随链接（审查 R9）
            var data = Data()
            while data.count < limit {
                let want = UInt32(min(32 * 1024, limit - data.count))
                guard let chunk = try await s.read(h, offset: UInt64(data.count), length: want),
                      !chunk.isEmpty else { break }
                data.append(chunk)
            }
            await s.closeHandle(h)
            return (data, version)
        } catch {
            await s.closeHandle(h); throw error
        }
    }

    /// 读取远端文件（base64 安全传输，二进制安全）。最多读取 `limit` 字节。
    /// 返回内容 + **版本令牌**（`mtime:size` 字符串，乐观锁用；stat 不可用时为 nil）。输出首行=版本，其余=base64。
    private func readViaShell(_ path: String, limit: Int) async -> Result<(data: Data, version: String?), RemoteFSError> {
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
        if isSftpUsable {
            do { return .success(try await sftpWrite(path, data: data, expectedVersion: expectedVersion)) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as RemoteFSError { return .failure(e) }                // 冲突等已映射
            catch let e as SFTPError { return .failure(RemoteFSError(message: e.isPermission ? "没有写入权限" : e.message)) }
            catch { return .failure(RemoteFSError(message: "保存失败")) }
        }
        return await writeViaShell(path, data: data, expectedVersion: expectedVersion)
    }

    /// SFTP 写：三态 STAT 冲突检测 → 写 .termo-tmp → 继承权限 → 原子改名（posix-rename 优先）→ 返回新版本令牌。
    private func sftpWrite(_ path: String, data: Data, expectedVersion: String?) async throws -> String {
        let s = session()
        let existing = try await sftpStatOrNil(path)        // 不存在→nil；transport→抛
        if let st = existing, let exp = expectedVersion, !exp.isEmpty {
            if let token = st.versionToken {
                if token != exp { throw RemoteFSError(message: "文件已被其他程序或会话修改", isConflict: true) }
            } else {
                throw RemoteFSError(message: "无法校验文件版本", isConflict: true)   // 存在但属性不全（审查 R6）
            }
        }
        let tmp = path + ".termo-tmp"
        let h = try await s.open(tmp, pflags: SFTPFlag.WRITE | SFTPFlag.CREAT | SFTPFlag.TRUNC)
        do {
            var off = 0
            while off < data.count {
                let end = min(off + 32 * 1024, data.count)
                let lo = data.index(data.startIndex, offsetBy: off)
                let hi = data.index(data.startIndex, offsetBy: end)
                try await s.write(h, offset: UInt64(off), data: data.subdata(in: lo..<hi))
                off = end
            }
            await s.closeHandle(h)
        } catch { await s.closeHandle(h); throw error }
        if let perm = existing?.permissions { try? await s.setPermissions(tmp, perm) }
        if await s.supportsPosixRename {
            try await s.posixRename(from: tmp, to: path)
        } else {
            do { try await s.rename(from: tmp, to: path) }
            catch { try? await s.remove(path); try await s.rename(from: tmp, to: path) }
        }
        return (try? await s.stat(path))?.versionToken ?? ""
    }

    private func writeViaShell(_ path: String, data: Data, expectedVersion: String?) async -> Result<String, RemoteFSError> {
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

    /// 删除文件或目录。目录递归删除 SFTP v3 无原生支持 → 恒走 shell `rm -rf`（审查 R19）。
    /// 目录删除恒走 shell `rm -rf`（可能较慢），可经 handle 中途取消；文件删除走 SFTP（瞬时，handle 不适用）。
    func delete(_ path: String, isDir: Bool, handle: CommandHandle? = nil) async -> Result<Void, RemoteFSError> {
        if isDir { return await deleteViaShell(path, isDir: true, handle: handle) }
        if isSftpUsable {
            do { try await session().remove(path); return .success(()) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isPermission ? "没有删除权限"
                    : (e.isNoSuchFile ? "文件不存在" : e.message)))
            }
            catch { return .failure(RemoteFSError(message: "删除失败")) }
        }
        return await deleteViaShell(path, isDir: false, handle: handle)
    }
    private func deleteViaShell(_ path: String, isDir: Bool,
                               handle: CommandHandle? = nil) async -> Result<Void, RemoteFSError> {
        let b64 = Data(path.utf8).base64EncodedString()
        let rm = isDir ? "rm -rf" : "rm -f"
        let cmd = "P=$(printf %s '\(b64)'|base64 -d); \(rm) -- \"$P\""
        let r = await run(cmd, handle: handle)
        if r.code != 0 {
            let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let msg = err.localizedCaseInsensitiveContains("permission") ? "没有删除权限"
                : (err.isEmpty ? "删除失败（退出码 \(r.code)）" : err)
            return .failure(RemoteFSError(message: msg))
        }
        return .success(())
    }

    /// 重命名 / 移动。目标已存在则拒绝，避免覆盖。
    func rename(_ from: String, to: String) async -> Result<Void, RemoteFSError> {
        if isSftpUsable {
            do {
                if try await sftpStatOrNil(to) != nil { return .failure(RemoteFSError(message: "目标名称已存在")) }
                try await session().rename(from: from, to: to)
                return .success(())
            }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                // RENAME v3 不覆盖：目标已存在通常回 FAILURE
                return .failure(RemoteFSError(message: e.isPermission ? "没有重命名权限" : "目标名称已存在"))
            }
            catch { return .failure(RemoteFSError(message: "重命名失败")) }
        }
        return await renameViaShell(from, to: to)
    }
    private func renameViaShell(_ from: String, to: String) async -> Result<Void, RemoteFSError> {
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
        if isSftpUsable {
            guard let m = UInt32(mode, radix: 8) else { return .failure(RemoteFSError(message: "权限值无效")) }
            do { try await session().setPermissions(path, m); return .success(()) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError { return .failure(RemoteFSError(message: e.isPermission ? "没有修改权限的权限" : e.message)) }
            catch { return .failure(RemoteFSError(message: "修改权限失败")) }
        }
        return await chmodViaShell(path, mode: mode)
    }
    private func chmodViaShell(_ path: String, mode: String) async -> Result<Void, RemoteFSError> {
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

    /// 路径是否存在。
    func exists(_ path: String) async -> Bool {
        if isSftpUsable {
            do { _ = try await session().stat(path); return true }
            catch let e as SFTPError where e.isNoSuchFile { return false }
            catch let e as SFTPError where e.isTransport { markSftpDown(); return await existsViaShell(path) }
            catch { return false }
        }
        return await existsViaShell(path)
    }
    private func existsViaShell(_ path: String) async -> Bool {
        let b64 = Data(path.utf8).base64EncodedString()
        let r = await run("P=$(printf %s '\(b64)'|base64 -d); [ -e \"$P\" ] && echo __Y__ || echo __N__")
        return (String(data: r.data, encoding: .utf8) ?? "").contains("__Y__")
    }

    /// 取当前权限（八进制低 12 位，含 setuid/setgid/sticky）。
    func statPerms(_ path: String) async -> Result<Int, RemoteFSError> {
        if isSftpUsable {
            do {
                guard let p = (try await session().stat(path)).permissions else {
                    return .failure(RemoteFSError(message: "无法读取权限"))
                }
                return .success(Int(p & 0o7777))
            }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch { return .failure(RemoteFSError(message: "无法读取权限")) }
        }
        return await statPermsViaShell(path)
    }
    private func statPermsViaShell(_ path: String) async -> Result<Int, RemoteFSError> {
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
        if isSftpUsable {
            do { let p = try await session().realpath("."); return p.isEmpty ? "/" : p }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch { /* 业务级失败：退到 shell */ }
        }
        return await homeViaShell()
    }
    private func homeViaShell() async -> String {
        let r = await run("cd && pwd")
        let s = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "/" : s
    }

    func list(_ path: String) async -> Result<[RemoteFile], RemoteFSError> {
        if isSftpUsable {
            do { return .success(try await sftpList(path)) }
            catch let e as SFTPError where e.isTransport { markSftpDown() }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isNoSuchFile ? "目录不存在"
                    : (e.isPermission ? "没有访问权限" : e.message)))
            }
            catch { return .failure(RemoteFSError(message: "列目录失败")) }
        }
        return await listViaShell(path)
    }

    private func sftpList(_ path: String) async throws -> [RemoteFile] {
        let s = session()
        let h = try await s.opendir(path)
        var files: [RemoteFile] = []
        do {
            while let batch = try await s.readdir(h) {
                for (name, attrs) in batch where name != "." && name != ".." {
                    files.append(RemoteFile(
                        name: name, path: join(path, name),
                        kind: kindFromMode(attrs.permissions),
                        size: Int64(attrs.size ?? 0),
                        modified: attrs.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }))
                }
            }
            await s.closeHandle(h)
        } catch {
            await s.closeHandle(h); throw error
        }
        return sorted(files)
    }

    /// 列出某绝对路径下的条目。优先 GNU `find -printf`（含大小/时间），失败回退到 `ls -1Ap`（仅名称/类型）。
    private func listViaShell(_ path: String) async -> Result<[RemoteFile], RemoteFSError> {
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
