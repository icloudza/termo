import AppKit
import SwiftTerm

/// 用 libssh2 交互式 shell 驱动一个 SwiftTerm 终端视图：作为 `TerminalView` 的 `terminalDelegate`，
/// 把用户输入/尺寸变化写入远端 PTY，把远端输出 `feed` 回视图——替代 `LocalProcessTerminalView` 起的
/// `/usr/bin/ssh` 子进程（终端类型全仓不变，仅 SSH 终端换掉这条传输层）。
///
/// 一个驱动 = 一条 dedicated `SSHSession` + 一个 C 层非阻塞 shell 泵线程（读/写/resize 全在该线程，杜绝
/// libssh2 并发）。退出码：远端 shell 退出码；掉线=255，与 ssh 对齐以触发上层重连。
final class SSHTerminalDriver: NSObject, TerminalViewDelegate, @unchecked Sendable {
    private weak var tv: LocalProcessTerminalView?
    private let ssh: SSHConnection
    private var session: SSHSession?
    private var shell: OpaquePointer?            // TermoSSHShell*
    private var closed = false
    private var terminatedReported = false

    var onCwd: ((String) -> Void)?
    var onTerminated: ((Int32?) -> Void)?

    init(tv: LocalProcessTerminalView, ssh: SSHConnection) {
        self.tv = tv
        self.ssh = ssh
        super.init()
    }

    // MARK: 连接 / 关闭

    /// 后台建连 + 开 shell + 启泵；连接/开壳失败按掉线(255)上报以触发重连。
    /// `initialLine` 在登录后注入（OSC7 钩子 + 可选 cd/初始命令）。
    func connect(cols: Int, rows: Int, initialLine: String) {
        let conn = ssh
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let a = conn.libssh2Auth
            guard let session = try? SSHSession.connect(host: conn.host, port: conn.port, user: conn.user,
                                                        password: a.password, keyPath: a.keyPath,
                                                        keyPassphrase: a.keyPassphrase),
                  let raw = session.rawHandle else {
                DispatchQueue.main.async { self.reportClosed(255) }   // 连接失败 → 当掉线触发重连
                return
            }
            let box = Unmanaged.passRetained(self).toOpaque()         // pump 持一份强引用，on_closed 时释放
            var err = [CChar](repeating: 0, count: 256)
            guard let sh = termo_ssh_shell_open(raw, Int32(cols), Int32(rows),
                                                Self.onData, Self.onClosed, box, &err, 256) else {
                Unmanaged<SSHTerminalDriver>.fromOpaque(box).release()
                session.close()
                DispatchQueue.main.async { self.reportClosed(255) }
                return
            }
            DispatchQueue.main.async {
                if self.closed {                 // 建连期间已被关闭：拆掉刚建的
                    termo_ssh_shell_close(sh)
                    session.close()
                    return
                }
                self.session = session
                self.shell = sh
                if !initialLine.isEmpty {
                    // 等远端 shell 的 rc 文件加载完，再注入 OSC7 钩子（否则可能被 .bashrc 覆盖）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.sendText(initialLine)
                    }
                }
            }
        }
    }

    /// 停泵 + 释放通道 + 关闭底层会话。幂等。
    func close() {
        guard !closed else { return }
        closed = true
        let sh = shell; shell = nil
        let sess = session; session = nil
        if let sh { termo_ssh_shell_close(sh) }     // 停 pump（join）→ 触发 on_closed 释放 box
        sess?.close()
    }

    /// 写入一段文本（初始命令注入用）。
    func sendText(_ text: String) {
        let bytes = Array(text.utf8)
        guard let shell, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { bp in
            bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bp.count) {
                _ = termo_ssh_shell_write(shell, $0, Int32(bp.count))
            }
        }
    }

    private func reportClosed(_ code: Int32) {
        guard !terminatedReported else { return }
        terminatedReported = true
        onTerminated?(code)
    }

    // MARK: C 回调（pump 线程）

    private static let onData: TermoSSHDataCallback = { ud, bytes, len in
        guard let ud, let bytes, len > 0 else { return }
        let driver = Unmanaged<SSHTerminalDriver>.fromOpaque(ud).takeUnretainedValue()
        let slice = bytes.withMemoryRebound(to: UInt8.self, capacity: Int(len)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(len)))
        }
        DispatchQueue.main.async { driver.tv?.feed(byteArray: slice[...]) }
    }

    private static let onClosed: TermoSSHClosedCallback = { ud, code in
        guard let ud else { return }
        let driver = Unmanaged<SSHTerminalDriver>.fromOpaque(ud).takeRetainedValue()   // 平衡 connect 的 passRetained
        DispatchQueue.main.async { driver.reportClosed(code) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let shell, !data.isEmpty else { return }
        data.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            _ = base.withMemoryRebound(to: CChar.self, capacity: bp.count) {
                termo_ssh_shell_write(shell, $0, Int32(bp.count))
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let shell else { return }
        _ = termo_ssh_shell_resize(shell, Int32(newCols), Int32(newRows))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let p = TerminalSessionDelegate.parsePath(directory) { onCwd?(p) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
