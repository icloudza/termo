import Foundation

// MARK: - SFTP 类型（公开给 RemoteFS）

/// open pflags（与 libssh2 LIBSSH2_FXF_* 同值，直接透传）。
enum SFTPFlag {
    static let READ: UInt32 = 0x1, WRITE: UInt32 = 0x2, APPEND: UInt32 = 0x4
    static let CREAT: UInt32 = 0x8, TRUNC: UInt32 = 0x10
}

private enum FX {     // SFTP 协议状态码（LIBSSH2_FX_*）
    static let NO_SUCH_FILE: UInt32 = 2
    static let PERMISSION_DENIED: UInt32 = 3
}

/// SFTP 错误。`code` 为协议 STATUS 码（或 ≥0xF000 的自定义大值）；`isTransport=true` 表示连接/底层级 → 触发回退 shell。
struct SFTPError: Error {
    let code: UInt32
    let message: String
    var isTransport = false
    var isNoSuchFile: Bool { code == FX.NO_SUCH_FILE }
    var isPermission: Bool { code == FX.PERMISSION_DENIED }
}

/// SFTP 文件属性（只取本端用到的字段）。
struct SFTPAttrs {
    var size: UInt64? = nil
    var permissions: UInt32? = nil
    var mtime: UInt32? = nil
    /// 版本令牌 "mtime:size"（乐观锁），缺字段时为 nil。
    var versionToken: String? {
        guard let m = mtime, let s = size else { return nil }
        return "\(m):\(s)"
    }
    init() {}
    init(_ a: TermoSFTPAttrs) {
        if a.has_size != 0 { size = a.size }
        if a.has_perm != 0 { permissions = a.permissions }
        if a.has_mtime != 0 { mtime = a.mtime }
    }
}

// MARK: - SFTP 会话（一个 host 一条 dedicated libssh2 连接 + SFTP 子系统，串行请求）

/// 基于 libssh2 的 SFTP 会话：懒建一条**独占** SSHSession（不入池——长驻、与短 exec 操作并发互不阻塞），
/// 在其上初始化 SFTP 子系统。libssh2 单会话非线程安全 → 所有调用经一条串行队列序列化；公开方法 async，
/// 内部把阻塞的 libssh2 调用派到串行队列、用 continuation 桥接，不阻塞调用方执行器。
/// 句柄对外是不透明 8 字节 `Data`（内部 id → 指针映射，避免上层持野指针）。
final class SFTPSession: @unchecked Sendable {
    private let ssh: SSHConnection
    private let queue = DispatchQueue(label: "termo.sftp")
    private var conn: SSHSession?                              // dedicated 连接
    private var sftp: UnsafeMutableRawPointer?                 // LIBSSH2_SFTP*
    private var failure: SFTPError?                            // 传输级失败后粘住（上层弃用本会话重建）
    private var handles: [UInt64: UnsafeMutableRawPointer] = [:]
    private var nextId: UInt64 = 1

    /// libssh2 经 rename_ex(NATIVE) 支持 posix-rename 原子覆盖；不支持的服务器在 posixRename 内回退。
    let supportsPosixRename = true

    init(_ ssh: SSHConnection) { self.ssh = ssh }

    // MARK: 串行执行

    /// 在串行队列上同步跑 block（保证 libssh2 单会话串行），async 包装不阻塞调用方。
    private func perform<T>(_ block: @escaping () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            queue.async { c.resume(returning: block()) }
        }
    }

    /// 懒建连接 + 初始化 SFTP 子系统（**须在串行队列上调**）。返回 nil=就绪、否则为失败原因。
    private func ensureLocked() -> SFTPError? {
        if let failure { return failure }
        if sftp != nil { return nil }
        do {
            let a = ssh.libssh2Auth
            let c = try SSHSession.connect(host: ssh.host, port: ssh.port, user: ssh.user,
                                           password: a.password, keyPath: a.keyPath, keyPassphrase: a.keyPassphrase)
            guard let raw = c.rawHandle, let sp = termo_sftp_init(raw) else {
                c.close()
                let e = SFTPError(code: 0xF001, message: String(localized: "SFTP 初始化失败"), isTransport: true)
                failure = e; return e
            }
            conn = c; sftp = sp
            return nil
        } catch {
            let msg = (error as? SSHSession.SSHError)?.message ?? String(localized: "SFTP 连接失败")
            let e = SFTPError(code: 0xF002, message: msg, isTransport: true)
            failure = e; return e
        }
    }

    /// 把 C 返回的状态码映射成 SFTPError；≥0xF000 视为传输错误并粘住失败（**须在串行队列上调**）。
    private func makeError(_ code: Int32) -> SFTPError {
        let c = UInt32(bitPattern: code)
        if c >= 0xF000 {
            let e = SFTPError(code: c, message: String(localized: "SFTP 连接错误"), isTransport: true)
            failure = e
            return e
        }
        return SFTPError(code: c, message: String(localized: "SFTP 错误 \(c)"))
    }

    // MARK: 句柄编解码（8 字节小端 id）

    private static func encode(_ id: UInt64) -> Data {
        var v = id.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
    private func handleId(_ data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        var v: UInt64 = 0
        for (i, b) in data.enumerated() { v |= UInt64(b) << (8 * i) }
        return v
    }
    private func handlePtr(_ data: Data) -> UnsafeMutableRawPointer? {
        guard let id = handleId(data) else { return nil }
        return handles[id]
    }
    private func badHandle() -> SFTPError { SFTPError(code: 0xF011, message: String(localized: "无效 SFTP 句柄"), isTransport: true) }

    // MARK: 生命周期

    /// 显式关闭（RemoteFS 各路径调用）。关掉所有句柄、SFTP 子系统与底层连接，幂等。
    func shutdown() async {
        await perform {
            for (_, hp) in self.handles { termo_sftp_close(hp) }
            self.handles.removeAll()
            if let sftp = self.sftp { termo_sftp_shutdown(sftp); self.sftp = nil }
            self.conn?.close(); self.conn = nil
            if self.failure == nil { self.failure = SFTPError(code: 0xF007, message: String(localized: "SFTP 已关闭"), isTransport: true) }
        }
    }

    // MARK: 路径/目录

    func realpath(_ path: String) async throws -> String {
        let r: Result<String, SFTPError> = await perform {
            if let e = self.ensureLocked() { return .failure(e) }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return .failure(self.makeError(0xF000)) }
            var buf = [CChar](repeating: 0, count: 4096)
            let rc = termo_sftp_realpath(raw, sftp, path, &buf, 4096)
            return rc == 0 ? .success(String(cString: buf)) : .failure(self.makeError(rc))
        }
        return try r.get()
    }

    func opendir(_ path: String) async throws -> Data {
        let r: Result<UInt64, SFTPError> = await perform {
            if let e = self.ensureLocked() { return .failure(e) }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return .failure(self.makeError(0xF000)) }
            guard let hp = termo_sftp_opendir(raw, sftp, path) else {
                let code = Int32(termo_sftp_last_errno(sftp))
                return .failure(self.makeError(code == 0 ? 0xF000 : code))
            }
            let id = self.nextId; self.nextId &+= 1
            self.handles[id] = hp
            return .success(id)
        }
        return Self.encode(try r.get())
    }

    /// 一批目录项（每次最多 512 条）；nil = 读到 EOF。
    func readdir(_ handle: Data) async throws -> [(name: String, attrs: SFTPAttrs)]? {
        let r: Result<[(String, SFTPAttrs)], SFTPError> = await perform {
            guard let hp = self.handlePtr(handle) else { return .failure(self.badHandle()) }
            var items: [(String, SFTPAttrs)] = []
            var nameBuf = [CChar](repeating: 0, count: 1024)
            for _ in 0..<512 {
                var a = TermoSFTPAttrs()
                let n = nameBuf.withUnsafeMutableBufferPointer { bp in
                    termo_sftp_readdir(hp, bp.baseAddress, 1024, &a)
                }
                if n > 0 { items.append((String(cString: nameBuf), SFTPAttrs(a))) }
                else if n == 0 { break }                       // EOF
                else { return .failure(SFTPError(code: 0xF000, message: String(localized: "SFTP 目录读取失败"), isTransport: true)) }
            }
            return .success(items)
        }
        let items = try r.get()
        return items.isEmpty ? nil : items.map { (name: $0.0, attrs: $0.1) }
    }

    func closeHandle(_ handle: Data) async {
        await perform {
            if let id = self.handleId(handle), let hp = self.handles.removeValue(forKey: id) {
                termo_sftp_close(hp)
            }
        }
    }

    // MARK: stat

    func stat(_ path: String) async throws -> SFTPAttrs { try await statImpl(path, follow: true) }
    func lstat(_ path: String) async throws -> SFTPAttrs { try await statImpl(path, follow: false) }
    private func statImpl(_ path: String, follow: Bool) async throws -> SFTPAttrs {
        let r: Result<SFTPAttrs, SFTPError> = await perform {
            if let e = self.ensureLocked() { return .failure(e) }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return .failure(self.makeError(0xF000)) }
            var a = TermoSFTPAttrs()
            let rc = termo_sftp_stat(raw, sftp, path, follow ? 1 : 0, &a)
            return rc == 0 ? .success(SFTPAttrs(a)) : .failure(self.makeError(rc))
        }
        return try r.get()
    }
    func fstat(_ handle: Data) async throws -> SFTPAttrs {
        let r: Result<SFTPAttrs, SFTPError> = await perform {
            guard let hp = self.handlePtr(handle) else { return .failure(self.badHandle()) }
            var a = TermoSFTPAttrs()
            let rc = termo_sftp_fstat(hp, &a)
            return rc == 0 ? .success(SFTPAttrs(a)) : .failure(self.makeError(rc))
        }
        return try r.get()
    }

    // MARK: 文件读写

    func open(_ path: String, pflags: UInt32) async throws -> Data {
        let r: Result<UInt64, SFTPError> = await perform {
            if let e = self.ensureLocked() { return .failure(e) }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return .failure(self.makeError(0xF000)) }
            guard let hp = termo_sftp_open(raw, sftp, path, pflags) else {
                let code = Int32(termo_sftp_last_errno(sftp))
                return .failure(self.makeError(code == 0 ? 0xF000 : code))
            }
            let id = self.nextId; self.nextId &+= 1
            self.handles[id] = hp
            return .success(id)
        }
        return Self.encode(try r.get())
    }

    /// 读一块；nil = EOF。
    func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        let r: Result<Data?, SFTPError> = await perform {
            guard let hp = self.handlePtr(handle) else { return .failure(self.badHandle()) }
            var buf = [UInt8](repeating: 0, count: Int(length))
            let n = buf.withUnsafeMutableBytes { mb in
                termo_sftp_read(hp, offset, mb.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(length))
            }
            if n > 0 { return .success(Data(buf.prefix(n))) }
            if n == 0 { return .success(nil) }                 // EOF
            return .failure(SFTPError(code: 0xF000, message: String(localized: "SFTP 读取失败"), isTransport: true))
        }
        return try r.get()
    }

    func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        let r: SFTPError? = await perform {
            guard let hp = self.handlePtr(handle) else { return self.badHandle() }
            if data.isEmpty { return nil }
            let n = data.withUnsafeBytes { rb in
                termo_sftp_write(hp, offset, rb.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count))
            }
            return n == data.count ? nil : SFTPError(code: 0xF000, message: String(localized: "SFTP 写入失败"), isTransport: true)
        }
        if let r { throw r }
    }

    // MARK: 改名/删除/权限

    func remove(_ path: String) async throws { try await simple { termo_sftp_unlink($0, $1, path) } }
    func rmdir(_ path: String) async throws  { try await simple { termo_sftp_rmdir($0, $1, path) } }
    func mkdir(_ path: String) async throws  { try await simple { termo_sftp_mkdir($0, $1, path) } }
    func setPermissions(_ path: String, _ mode: UInt32) async throws {
        try await simple { termo_sftp_setstat_perm($0, $1, path, mode) }
    }
    func rename(from: String, to: String) async throws {
        try await simple { termo_sftp_rename($0, $1, from, to, 0) }
    }
    /// posix-rename 原子覆盖；服务器不支持时回退「删目标+普通改名」（牺牲原子性但保功能）。
    func posixRename(from: String, to: String) async throws {
        let r: SFTPError? = await perform {
            if let e = self.ensureLocked() { return e }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return self.makeError(0xF000) }
            if termo_sftp_rename(raw, sftp, from, to, 1) == 0 { return nil }
            _ = termo_sftp_unlink(raw, sftp, to)
            let rc2 = termo_sftp_rename(raw, sftp, from, to, 0)
            return rc2 == 0 ? nil : self.makeError(rc2)
        }
        if let r { throw r }
    }

    private func simple(_ op: @escaping (OpaquePointer, UnsafeMutableRawPointer) -> Int32) async throws {
        let r: SFTPError? = await perform {
            if let e = self.ensureLocked() { return e }
            guard let raw = self.conn?.rawHandle, let sftp = self.sftp else { return self.makeError(0xF000) }
            let rc = op(raw, sftp)
            return rc == 0 ? nil : self.makeError(rc)
        }
        if let r { throw r }
    }
}
