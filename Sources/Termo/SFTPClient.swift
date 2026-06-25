import Foundation

// MARK: - SFTP v3（draft-ietf-secsh-filexfer-02）协议常量

private enum FXP {
    static let INIT: UInt8 = 1, VERSION: UInt8 = 2
    static let OPEN: UInt8 = 3, CLOSE: UInt8 = 4, READ: UInt8 = 5, WRITE: UInt8 = 6
    static let LSTAT: UInt8 = 7, FSTAT: UInt8 = 8, SETSTAT: UInt8 = 9
    static let OPENDIR: UInt8 = 11, READDIR: UInt8 = 12, REMOVE: UInt8 = 13
    static let MKDIR: UInt8 = 14, RMDIR: UInt8 = 15, REALPATH: UInt8 = 16
    static let STAT: UInt8 = 17, RENAME: UInt8 = 18
    static let EXTENDED: UInt8 = 200
    static let STATUS: UInt8 = 101, HANDLE: UInt8 = 102, DATA: UInt8 = 103, NAME: UInt8 = 104, ATTRS: UInt8 = 105
}
private enum FX {     // status codes
    static let OK: UInt32 = 0, EOF: UInt32 = 1, NO_SUCH_FILE: UInt32 = 2
    static let PERMISSION_DENIED: UInt32 = 3
}
enum SFTPFlag {       // open pflags（公开给 RemoteFS 拼组合）
    static let READ: UInt32 = 0x1, WRITE: UInt32 = 0x2, APPEND: UInt32 = 0x4
    static let CREAT: UInt32 = 0x8, TRUNC: UInt32 = 0x10
}
private enum AF {     // attr flags
    static let SIZE: UInt32 = 0x1, UIDGID: UInt32 = 0x2, PERMISSIONS: UInt32 = 0x4
    static let ACMODTIME: UInt32 = 0x8, EXTENDED: UInt32 = 0x80000000
}

/// SFTP 错误。`code` 为协议 STATUS 码（或自定义大值）；`isTransport=true` 表示连接/握手级 → 触发回退 shell。
struct SFTPError: Error {
    let code: UInt32
    let message: String
    var isTransport = false
    var isNoSuchFile: Bool { code == FX.NO_SUCH_FILE }
    var isPermission: Bool { code == FX.PERMISSION_DENIED }
}

/// SFTP 文件属性（只取本 App 需要的字段）。
struct SFTPAttrs {
    var size: UInt64? = nil
    var permissions: UInt32? = nil
    var mtime: UInt32? = nil
    /// 版本令牌 "mtime:size"（乐观锁），缺字段时为 nil。
    var versionToken: String? {
        guard let m = mtime, let s = size else { return nil }
        return "\(m):\(s)"
    }
}

// MARK: - 字节编解码（全部大端 / 逐字节，绝不 load(as:) ）

private func appendU32(_ d: inout Data, _ v: UInt32) {
    d.append(UInt8(v >> 24)); d.append(UInt8((v >> 16) & 0xFF))
    d.append(UInt8((v >> 8) & 0xFF)); d.append(UInt8(v & 0xFF))
}
private func appendU64(_ d: inout Data, _ v: UInt64) {
    for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8((v >> UInt64(s)) & 0xFF)) }
}
private func appendStr(_ d: inout Data, _ s: String) {
    let b = Data(s.utf8); appendU32(&d, UInt32(b.count)); d.append(b)
}
private func appendBytes(_ d: inout Data, _ b: Data) {   // string 载二进制（handle / write data）
    appendU32(&d, UInt32(b.count)); d.append(b)
}

/// 游标读取器：构造时把 Data 复制成 0-based 连续数组，杜绝切片 startIndex / 对齐问题（审查 R1）。
private struct Reader {
    private let b: [UInt8]; private var i = 0
    init(_ d: Data) { self.b = [UInt8](d) }
    var remaining: Int { b.count - i }
    private func ck(_ n: Int) throws { guard n >= 0, i + n <= b.count else { throw SFTPError(code: 0xFFFF, message: "SFTP 解析越界") } }
    mutating func u8() throws -> UInt8 { try ck(1); defer { i += 1 }; return b[i] }
    mutating func u32() throws -> UInt32 {
        try ck(4); defer { i += 4 }
        return UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16 | UInt32(b[i+2]) << 8 | UInt32(b[i+3])
    }
    mutating func u64() throws -> UInt64 {
        try ck(8); defer { i += 8 }
        var v: UInt64 = 0; for k in 0..<8 { v = v << 8 | UInt64(b[i+k]) }; return v
    }
    mutating func take(_ n: Int) throws -> Data { try ck(n); defer { i += n }; return Data(b[i..<i+n]) }
    mutating func bytes() throws -> Data { try take(Int(try u32())) }
    mutating func str() throws -> String { String(decoding: try take(Int(try u32())), as: UTF8.self) }
}

private func beU32(_ d: Data) -> UInt32 {
    let b = [UInt8](d); return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
}

/// ATTRS：字段顺序铁律 SIZE→UIDGID→PERMISSIONS→ACMODTIME→EXTENDED，按 flag 位条件出现（审查 R3）。
private func readAttrs(_ r: inout Reader) throws -> SFTPAttrs {
    var a = SFTPAttrs()
    let flags = try r.u32()
    if flags & AF.SIZE != 0        { a.size = try r.u64() }
    if flags & AF.UIDGID != 0      { _ = try r.u32(); _ = try r.u32() }
    if flags & AF.PERMISSIONS != 0 { a.permissions = try r.u32() }
    if flags & AF.ACMODTIME != 0   { _ = try r.u32(); a.mtime = try r.u32() }   // atime 在前、mtime 在后
    if flags & AF.EXTENDED != 0 {
        let n = try r.u32()
        for _ in 0..<n { _ = try r.bytes(); _ = try r.bytes() }
    }
    return a
}

/// 从 ssh stdout 精确读 n 字节；EOF/错误返回 nil。
private func readN(_ fh: FileHandle, _ n: Int) -> Data? {
    var buf = Data(); buf.reserveCapacity(n)
    while buf.count < n {
        let chunk = (try? fh.read(upToCount: n - buf.count)) ?? nil
        guard let c = chunk, !c.isEmpty else { return nil }
        buf.append(c)
    }
    return buf
}

// MARK: - SFTP 会话（一个 host 一条长驻 ssh -s sftp 连接，串行请求）

actor SFTPSession {
    private let ssh: SSHConnection
    private var process: Process?
    private var outFH: FileHandle?            // ssh stdin（我方写请求）
    private var startedHandshake = false
    private var ready = false
    private var failure: Error?
    private var nextId: UInt32 = 1
    private var waiters: [UInt32: CheckedContinuation<(UInt8, Data), Error>] = [:]
    private var versionWaiter: CheckedContinuation<Void, Error>?
    /// 串行闸：最多 1 个在途请求（审查 R11，杜绝同步写阻塞 actor 的死锁）。
    private var busy = false
    private var turnQueue: [CheckedContinuation<Void, Never>] = []

    private(set) var supportsPosixRename = false

    init(_ ssh: SSHConnection) { self.ssh = ssh }

    // MARK: 串行闸

    private func acquireTurn() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { turnQueue.append($0) }
    }
    private func releaseTurn() {
        if turnQueue.isEmpty { busy = false } else { turnQueue.removeFirst().resume() }
    }

    // MARK: 启动 + 握手

    private func ensureStarted() async throws {
        if let failure { throw failure }
        if ready { return }
        if startedHandshake { return }   // 同一 turn 内不会重入；保险
        startedHandshake = true

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ssh.sshArguments(multiplex: true)   // 末元素 = user@host
        let dest = args.removeLast()
        args += ["-o", "BatchMode=no", "-s", "--", dest, "sftp"]
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        if ssh.needsAskpass, let ap = SSHAskpass.envVars(password: ssh.password) {
            for (k, v) in ap { env[k] = v }
        }
        proc.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.terminationHandler = { [weak self] _ in
            Task { await self?.failAll(SFTPError(code: 0xF001, message: "SFTP 连接已结束", isTransport: true)) }
        }
        do { try proc.run() }
        catch {
            let e = SFTPError(code: 0xF002, message: "无法启动 SFTP 子系统", isTransport: true)
            failure = e; throw e
        }
        process = proc
        outFH = inPipe.fileHandleForWriting

        // stderr 必须持续排空，否则 64KB 满会让 ssh 在认证阶段阻塞（审查 R16）
        DispatchQueue.global().async { _ = errPipe.fileHandleForReading.readDataToEndOfFile() }
        startReadLoop(outPipe.fileHandleForReading)

        // 发 INIT(version=3)
        var body = Data(); appendU32(&body, 3)
        var pkt = Data(); appendU32(&pkt, UInt32(1 + body.count)); pkt.append(FXP.INIT); pkt.append(body)
        try? outFH?.write(contentsOf: pkt)

        // 握手看门狗（审查 R12）
        let wd = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            await self?.handshakeTimeout()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            versionWaiter = c
        }
        wd.cancel()
        ready = true
    }

    private func handshakeTimeout() {
        if versionWaiter != nil { failAll(SFTPError(code: 0xF003, message: "SFTP 握手超时", isTransport: true)) }
    }

    private func startReadLoop(_ fh: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                guard let lenData = readN(fh, 4) else {
                    Task { await self?.failAll(SFTPError(code: 0xF004, message: "SFTP 连接中断", isTransport: true)) }
                    return
                }
                let len = Int(beU32(lenData))
                guard len >= 1, len <= 256 * 1024 * 1024, let body = readN(fh, len) else {
                    Task { await self?.failAll(SFTPError(code: 0xF005, message: "SFTP 帧异常", isTransport: true)) }
                    return
                }
                let type = body[body.startIndex]
                let payload = body.subdata(in: body.index(after: body.startIndex)..<body.endIndex)
                Task { await self?.deliver(type: type, payload: payload) }
            }
        }
    }

    private func deliver(type: UInt8, payload: Data) {
        if type == FXP.VERSION {
            var r = Reader(payload)
            _ = try? r.u32()                       // version
            while r.remaining >= 4 {               // 扩展对：探测 posix-rename
                guard let name = try? r.str(), (try? r.str()) != nil else { break }
                if name == "posix-rename@openssh.com" { supportsPosixRename = true }
            }
            versionWaiter?.resume(); versionWaiter = nil
            return
        }
        // 其它响应：首字段是 request-id
        var r = Reader(payload)
        guard let id = try? r.u32(), let cont = waiters.removeValue(forKey: id) else {
            // 串行模型下未知 id = 协议错位 → 立即暴露而非退化成挂起（审查 R13）
            failAll(SFTPError(code: 0xF006, message: "SFTP 协议错位", isTransport: true))
            return
        }
        let rest = payload.subdata(in: payload.index(payload.startIndex, offsetBy: 4)..<payload.endIndex)
        cont.resume(returning: (type, rest))
    }

    private func failAll(_ error: Error) {
        if failure == nil { failure = error }
        let pending = waiters; waiters.removeAll()
        let vw = versionWaiter; versionWaiter = nil
        for (_, c) in pending { c.resume(throwing: error) }
        vw?.resume(throwing: error)               // 必须，否则握手永挂（审查 R12）
        try? outFH?.close(); outFH = nil
        if process?.isRunning == true { process?.terminate() }
        ready = false
    }

    /// 显式关闭（RemoteFS.closeMaster 前调用）。
    func shutdown() { failAll(SFTPError(code: 0xF007, message: "SFTP 已关闭", isTransport: true)) }

    // MARK: 通用请求（串行）

    /// `fields` = request-id 之后的字段。返回 (响应 type, id 之后的负载)。
    private func request(_ type: UInt8, _ fields: Data) async throws -> (UInt8, Data) {
        await acquireTurn()
        defer { releaseTurn() }
        try await ensureStarted()
        if let failure { throw failure }
        let id = nextId; nextId &+= 1
        var pkt = Data()
        appendU32(&pkt, UInt32(1 + 4 + fields.count))   // length = type(1) + id(4) + fields
        pkt.append(type); appendU32(&pkt, id); pkt.append(fields)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(UInt8, Data), Error>) in
            guard let out = outFH else {
                cont.resume(throwing: SFTPError(code: 0xF008, message: "SFTP 未连接", isTransport: true)); return
            }
            waiters[id] = cont
            do { try out.write(contentsOf: pkt) }
            catch {
                waiters[id] = nil
                cont.resume(throwing: SFTPError(code: 0xF009, message: "SFTP 写入失败", isTransport: true))
            }
        }
    }

    // 把 STATUS 响应解释为成功/抛错
    private func throwStatus(_ reply: (UInt8, Data)) throws {
        guard reply.0 == FXP.STATUS else { throw SFTPError(code: 0xF00A, message: "SFTP 非预期响应") }
        var r = Reader(reply.1); let code = try r.u32()
        if code == FX.OK { return }
        throw SFTPError(code: code, message: (try? r.str()) ?? "SFTP 错误 \(code)")
    }
    private func handleFrom(_ t: UInt8, _ p: Data) throws -> Data {
        if t == FXP.HANDLE { var r = Reader(p); return try r.bytes() }
        try throwStatus((t, p)); return Data()
    }
    private func attrsFrom(_ t: UInt8, _ p: Data) throws -> SFTPAttrs {
        if t == FXP.ATTRS { var r = Reader(p); return try readAttrs(&r) }
        try throwStatus((t, p)); return SFTPAttrs()
    }

    // MARK: 高层操作

    func realpath(_ path: String) async throws -> String {
        var f = Data(); appendStr(&f, path)
        let (t, p) = try await request(FXP.REALPATH, f)
        if t == FXP.NAME {
            var r = Reader(p)
            guard try r.u32() >= 1 else { throw SFTPError(code: 0xF00B, message: "SFTP REALPATH 空") }
            return try r.str()
        }
        try throwStatus((t, p)); return path
    }

    func opendir(_ path: String) async throws -> Data {
        var f = Data(); appendStr(&f, path)
        let (t, p) = try await request(FXP.OPENDIR, f); return try handleFrom(t, p)
    }

    /// 一批目录项；nil = 读到 EOF（结束）。
    func readdir(_ handle: Data) async throws -> [(name: String, attrs: SFTPAttrs)]? {
        var f = Data(); appendBytes(&f, handle)
        let (t, p) = try await request(FXP.READDIR, f)
        if t == FXP.STATUS {
            var r = Reader(p); let code = try r.u32()
            if code == FX.EOF { return nil }
            throw SFTPError(code: code, message: (try? r.str()) ?? "SFTP 错误 \(code)")
        }
        guard t == FXP.NAME else { throw SFTPError(code: 0xF00C, message: "SFTP READDIR 非预期响应") }
        var r = Reader(p)
        let count = try r.u32()
        var out: [(String, SFTPAttrs)] = []
        for _ in 0..<count {
            let name = try r.str()
            _ = try r.str()                 // longname（丢弃）
            out.append((name, try readAttrs(&r)))
        }
        return out
    }

    func closeHandle(_ handle: Data) async {
        var f = Data(); appendBytes(&f, handle)
        _ = try? await request(FXP.CLOSE, f)
    }

    func stat(_ path: String) async throws -> SFTPAttrs {
        var f = Data(); appendStr(&f, path)
        let (t, p) = try await request(FXP.STAT, f); return try attrsFrom(t, p)
    }
    func lstat(_ path: String) async throws -> SFTPAttrs {
        var f = Data(); appendStr(&f, path)
        let (t, p) = try await request(FXP.LSTAT, f); return try attrsFrom(t, p)
    }
    func fstat(_ handle: Data) async throws -> SFTPAttrs {
        var f = Data(); appendBytes(&f, handle)
        let (t, p) = try await request(FXP.FSTAT, f); return try attrsFrom(t, p)
    }

    func open(_ path: String, pflags: UInt32) async throws -> Data {
        var f = Data(); appendStr(&f, path); appendU32(&f, pflags); appendU32(&f, 0)   // 空 attrs
        let (t, p) = try await request(FXP.OPEN, f); return try handleFrom(t, p)
    }

    /// 读一块；nil = EOF。
    func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        var f = Data(); appendBytes(&f, handle); appendU64(&f, offset); appendU32(&f, length)
        let (t, p) = try await request(FXP.READ, f)
        if t == FXP.DATA { var r = Reader(p); return try r.bytes() }
        if t == FXP.STATUS {
            var r = Reader(p); let code = try r.u32()
            if code == FX.EOF { return nil }
            throw SFTPError(code: code, message: (try? r.str()) ?? "SFTP 错误 \(code)")
        }
        throw SFTPError(code: 0xF00D, message: "SFTP READ 非预期响应")
    }

    func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        var f = Data(); appendBytes(&f, handle); appendU64(&f, offset); appendBytes(&f, data)
        try throwStatus(try await request(FXP.WRITE, f))
    }

    func remove(_ path: String) async throws { var f = Data(); appendStr(&f, path); try throwStatus(try await request(FXP.REMOVE, f)) }
    func rmdir(_ path: String) async throws  { var f = Data(); appendStr(&f, path); try throwStatus(try await request(FXP.RMDIR, f)) }
    func mkdir(_ path: String) async throws  { var f = Data(); appendStr(&f, path); appendU32(&f, 0); try throwStatus(try await request(FXP.MKDIR, f)) }

    func rename(from: String, to: String) async throws {
        var f = Data(); appendStr(&f, from); appendStr(&f, to)
        try throwStatus(try await request(FXP.RENAME, f))
    }
    /// posix-rename@openssh.com：原子覆盖目标（握手探测到才用）。
    func posixRename(from: String, to: String) async throws {
        var f = Data(); appendStr(&f, "posix-rename@openssh.com"); appendStr(&f, from); appendStr(&f, to)
        try throwStatus(try await request(FXP.EXTENDED, f))
    }
    func setPermissions(_ path: String, _ mode: UInt32) async throws {
        var f = Data(); appendStr(&f, path); appendU32(&f, AF.PERMISSIONS); appendU32(&f, mode & 0o7777)
        try throwStatus(try await request(FXP.SETSTAT, f))
    }
}
