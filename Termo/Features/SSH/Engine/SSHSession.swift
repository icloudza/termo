import Foundation

/// 一条已认证的进程内 SSH 连接（libssh2）。其上可反复 exec（后续扩展 SFTP/PTY/转发）。
/// libssh2 单会话非线程安全：本类用一个**串行队列**序列化对底层句柄的所有调用。
/// 阻塞式：connect/exec 都同步、会阻塞调用线程，务必在后台队列使用。
final class SSHSession: @unchecked Sendable {
    struct SSHError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        /// 主机密钥与已知记录不匹配（疑似 MITM）——上层可据此给出区别于普通失败的提示。
        var isHostKeyMismatch: Bool { message.hasPrefix("HOSTKEY_MISMATCH") }
    }
    struct ExecResult { let output: String; let stderr: String; let exitCode: Int }
    /// 二进制安全的 exec 结果（供 RemoteFS.run）：stdout/stderr 为原始字节，timedOut/cancelled 标识非正常结束。
    struct ExecBytes { let stdout: Data; let stderr: Data; let exitCode: Int32; let timedOut: Bool; let cancelled: Bool }

    private var handle: OpaquePointer?          // TermoSSHSession*
    private let queue: DispatchQueue
    let fingerprintSHA256: String
    let fingerprintMD5: String

    private init(handle: OpaquePointer, queue: DispatchQueue) {
        self.handle = handle
        self.queue = queue
        self.fingerprintSHA256 = String(cString: termo_ssh_session_sha256(handle))
        self.fingerprintMD5 = String(cString: termo_ssh_session_md5(handle))
    }

    /// 连接 + 握手 + 认证（同步，务必后台调用）。keyPath 非空走公钥认证。
    /// 握手后认证前对照 known_hosts 校验主机密钥：仅明确不匹配（疑似 MITM）才抛错拒绝；未知主机放行。
    static func connect(host: String, port: Int, user: String,
                        password: String?, keyPath: String?, keyPassphrase: String?) throws -> SSHSession {
        var err = [CChar](repeating: 0, count: 256)
        let real = HostKeyVerifier.realKnownHosts
        let session = HostKeyVerifier.sessionKnownHosts
        guard let h = termo_ssh_open(host, Int32(port), user, password, keyPath, keyPassphrase,
                                     real, session, &err, 256) else {
            throw SSHError(message: String(cString: err))
        }
        return SSHSession(handle: h, queue: DispatchQueue(label: "termo.ssh.\(host):\(port)"))
    }

    /// exec 一条命令，读回 stdout/stderr/退出码。
    func exec(_ command: String, outCap: Int = 1 << 18, errCap: Int = 8192) throws -> ExecResult {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "会话已关闭")) }
            var out = [CChar](repeating: 0, count: outCap)
            var errout = [CChar](repeating: 0, count: errCap)
            var exitCode: Int32 = 0
            var err = [CChar](repeating: 0, count: 256)
            let rc = termo_ssh_exec(h, command, &out, Int32(outCap), &errout, Int32(errCap), &exitCode, &err, 256)
            if rc != 0 { throw SSHError(message: String(cString: err)) }
            return ExecResult(output: String(cString: out), stderr: String(cString: errout), exitCode: Int(exitCode))
        }
    }

    /// 二进制安全 exec（带 stdin/整体超时/可取消，**同步阻塞**，务必后台调用）。供 RemoteFS.run。
    /// 超时/取消不抛错（看返回的 timedOut/cancelled）；通道级错误抛 SSHError。
    func execBytes(_ command: String, stdin: Data? = nil, timeout: Double,
                   outCap: Int = 1 << 20, errCap: Int = 1 << 16) throws -> ExecBytes {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "会话已关闭")) }
            var out = [CChar](repeating: 0, count: outCap)
            var errb = [CChar](repeating: 0, count: errCap)
            var outLen: Int32 = 0, errLen: Int32 = 0, code: Int32 = 0
            var emsg = [CChar](repeating: 0, count: 256)
            let tmo = Int32((max(1, min(timeout, 86_400)) * 1000).rounded())
            let rc: Int32
            if let data = stdin, !data.isEmpty {
                rc = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    termo_ssh_exec2(h, command,
                                    raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count),
                                    &out, Int32(outCap), &outLen, &errb, Int32(errCap), &errLen,
                                    &code, tmo, &emsg, 256)
                }
            } else {
                rc = termo_ssh_exec2(h, command, nil, 0,
                                     &out, Int32(outCap), &outLen, &errb, Int32(errCap), &errLen,
                                     &code, tmo, &emsg, 256)
            }
            if rc == -1 { throw SSHError(message: String(cString: emsg)) }
            let outData = Data(bytes: out, count: Int(outLen))
            let errData = Data(bytes: errb, count: Int(errLen))
            return ExecBytes(stdout: outData, stderr: errData, exitCode: code,
                             timedOut: rc == 1, cancelled: rc == 2)
        }
    }

    /// 流式上传 exec（替代 spawn ssh + cat）：pull 每次被调用填 buf（≤cap），返回写入字节 / 0=结束 / <0=取消。
    /// 返回 (rc, exitCode)：rc 0=完成 1=被取消 ；通道级错误抛 SSHError。**同步阻塞**，务必后台调用。
    private final class PullBox {
        let pull: (UnsafeMutablePointer<CChar>, Int32) -> Int32
        init(_ pull: @escaping (UnsafeMutablePointer<CChar>, Int32) -> Int32) { self.pull = pull }
    }
    func execUpload(_ command: String,
                    pull: @escaping (UnsafeMutablePointer<CChar>, Int32) -> Int32) throws -> (rc: Int, exitCode: Int) {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "会话已关闭")) }
            let box = Unmanaged.passRetained(PullBox(pull)).toOpaque()
            defer { Unmanaged<PullBox>.fromOpaque(box).release() }
            var exitCode: Int32 = 0
            var err = [CChar](repeating: 0, count: 256)
            let rc = termo_ssh_exec_upload(h, command, { ud, buf, cap in
                guard let ud, let buf else { return -1 }
                return Unmanaged<PullBox>.fromOpaque(ud).takeUnretainedValue().pull(buf, cap)
            }, box, &exitCode, &err, 256)
            if rc == -1 { throw SSHError(message: String(cString: err)) }
            return (Int(rc), Int(exitCode))
        }
    }

    /// 流式 exec（**同步阻塞当前线程**直到 EOF/错误/被 cancel）。务必在专用后台线程调用：
    /// 一个会话同时只跑一个流（HostMonitor 等用独立会话）。onData 在该后台线程回调。
    private final class DataBox { let onData: (Data) -> Void; init(_ f: @escaping (Data) -> Void) { onData = f } }
    func execStream(_ command: String, onData: @escaping (Data) -> Void) {
        guard let h = handle else { return }
        let box = Unmanaged.passRetained(DataBox(onData)).toOpaque()
        var err = [CChar](repeating: 0, count: 256)
        termo_ssh_exec_stream(h, command, { ud, bytes, len in
            guard let ud, let bytes, len > 0 else { return }
            let cb = Unmanaged<DataBox>.fromOpaque(ud).takeUnretainedValue()
            cb.onData(Data(bytes: bytes, count: Int(len)))
        }, box, &err, 256)
        Unmanaged<DataBox>.fromOpaque(box).release()
    }

    /// 打断正在跑的流（仅置 C 层 volatile 标志，可从任意线程调用，不走串行队列以免与阻塞中的流死锁）。
    func cancel() {
        if let h = handle { termo_ssh_cancel(h) }
    }

    /// 底层 TermoSSHSession* 句柄，供 SFTP C 调用使用。仅在持有方自己的串行队列上读用（SFTP 用独占会话）。
    var rawHandle: OpaquePointer? { handle }

    func close() {
        queue.sync {
            if let h = handle { termo_ssh_close(h); handle = nil }
        }
    }

    deinit {
        // 兜底：正常应先 close()。deinit 时无其它引用、无并发，可直接释放。
        if let h = handle { termo_ssh_close(h) }
    }
}
