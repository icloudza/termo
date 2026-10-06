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

    // 远端 PTY 尺寸（仅主线程读写）。建连是异步的，期间布局产生的尺寸变化必须记下、开壳后补发：
    // 否则远端一直停在建连那一刻的占位尺寸（vim/top 只占半屏、换行错乱）。
    private var wantedSize = (cols: 80, rows: 24)
    private var sentSize: (cols: Int, rows: Int)?
    private var resizeWork: DispatchWorkItem?
    private static let resizeDebounce = 0.06     // 拖动/动画期间合并成一次 window-change，避免远端 shell 反复重绘提示符

    // pump 线程的输出先攒进收件箱，主线程整批喂给终端：合并多次 read，减少主队列调度与重绘次数。
    private let inboxLock = NSLock()
    private var inbox: [UInt8] = []
    private var drainScheduled = false
    private var inboxClosed = false
    private static let maxFeedPerDrain = 256 * 1024
    // 主线程消化不过来时让 pump 暂停读取（SSH 流控随之让远端停发），刷屏时 Ctrl+C 才能及时生效、内存不会无限涨。
    private static let inboxHighWater = 4 * 1024 * 1024
    private static let inboxLowWater = 1024 * 1024

    // 新开终端建连期间（shell 还没开好）用户敲的键、终端对远端查询的应答先攒着，开壳后补发，不再直接丢掉。
    // 断线重连不攒：用户对着「连接已断开」覆盖层敲的键不该在重连后被执行。
    private var bufferEarlyInput = true
    private var pendingInput: [UInt8] = []
    private static let pendingInputCap = 64 * 1024

    var onCwd: ((String) -> Void)?
    var onTerminated: ((Int32?) -> Void)?
    var onConnected: (() -> Void)?                 // shell 已开好（主线程）
    var onConnectFailed: ((String) -> Void)?       // 建连/开壳失败原因（主线程，随后照常以 255 上报退出）

    init(tv: LocalProcessTerminalView, ssh: SSHConnection) {
        self.tv = tv
        self.ssh = ssh
        super.init()
    }

    // MARK: 连接 / 关闭

    /// 后台建连 + 开 shell + 启泵；连接/开壳失败按掉线(255)上报以触发重连。
    /// `initialLine` 在登录后注入（OSC7 钩子 + 可选 cd/初始命令）。
    func connect(cols: Int, rows: Int, initialLine: String, bufferEarlyInput: Bool = true) {
        self.bufferEarlyInput = bufferEarlyInput
        wantedSize = (max(cols, 1), max(rows, 1))
        let openSize = wantedSize
        let conn = ssh
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let session: SSHSession
            do { session = try SSHSession.connect(conn) } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async { self.onConnectFailed?(msg); self.reportClosed(255) }   // 连接失败 → 当掉线触发重连
                return
            }
            guard let raw = session.rawHandle else {
                DispatchQueue.main.async { self.reportClosed(255) }
                return
            }
            let box = Unmanaged.passRetained(self).toOpaque()         // pump 持一份强引用，on_closed 时释放
            var err = [CChar](repeating: 0, count: 256)
            guard let sh = termo_ssh_shell_open(raw, Int32(openSize.cols), Int32(openSize.rows), conn.remoteLocale,
                                                Self.onData, Self.onClosed, box, &err, 256) else {
                Unmanaged<SSHTerminalDriver>.fromOpaque(box).release()
                session.close()
                let msg = String(cString: err)
                DispatchQueue.main.async {
                    if !msg.isEmpty { self.onConnectFailed?(msg) }
                    self.reportClosed(255)
                }
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
                self.sentSize = openSize
                self.onConnected?()
                self.flushResize()               // 建连期间视图已按真实布局改过尺寸 → 立刻同步给远端
                if !self.pendingInput.isEmpty {
                    let bytes = self.pendingInput
                    self.pendingInput = []
                    self.write(bytes[...])
                }
                if !initialLine.isEmpty {
                    // 等远端 shell 的 rc 文件加载完，再注入 OSC7 钩子（否则可能被 .bashrc 覆盖）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.sendText(initialLine)   // 期间已关闭则 shell 为 nil，空操作
                    }
                }
            }
        }
    }

    /// 停泵 + 释放通道 + 关闭底层会话。幂等。
    func close() {
        guard !closed else { return }
        closed = true
        resizeWork?.cancel()
        resizeWork = nil
        // 先放行可能卡在背压等待里的 pump，再 join：否则主线程等 pump、pump 等主线程消化收件箱，互相死等。
        inboxLock.lock(); inboxClosed = true; inbox.removeAll(); inboxLock.unlock()
        pendingInput = []
        let sh = shell; shell = nil
        let sess = session; session = nil
        if let sh { termo_ssh_shell_close(sh) }     // 停 pump（join）→ 触发 on_closed 释放 box
        sess?.close()
    }

    private func write(_ data: ArraySlice<UInt8>) {
        guard let shell, !data.isEmpty else { return }
        data.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            _ = base.withMemoryRebound(to: CChar.self, capacity: bp.count) {
                termo_ssh_shell_write(shell, $0, Int32(bp.count))
            }
        }
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

    // MARK: 尺寸同步

    private func scheduleResize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushResize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeDebounce, execute: work)
    }

    private func flushResize() {
        resizeWork = nil
        guard let shell, let sent = sentSize, sent != wantedSize else { return }
        sentSize = wantedSize
        _ = termo_ssh_shell_resize(shell, Int32(wantedSize.cols), Int32(wantedSize.rows))
    }

    // MARK: 输出（pump 线程 → 主线程）

    private func enqueue(_ bytes: UnsafeRawBufferPointer) {
        inboxLock.lock()
        if inboxClosed { inboxLock.unlock(); return }
        inbox.append(contentsOf: bytes)
        let needSchedule = !drainScheduled
        drainScheduled = true
        var backlog = inbox.count
        inboxLock.unlock()
        if needSchedule {
            DispatchQueue.main.async { [weak self] in self?.drain() }
        }
        // 背压：在 pump 线程上等主线程消化到低水位再继续读。
        guard backlog > Self.inboxHighWater else { return }
        repeat {
            usleep(2_000)
            inboxLock.lock(); backlog = inboxClosed ? 0 : inbox.count; inboxLock.unlock()
        } while backlog > Self.inboxLowWater
    }

    private func drain() {
        inboxLock.lock()
        let chunk: [UInt8]
        if inbox.count <= Self.maxFeedPerDrain {
            chunk = inbox
            inbox.removeAll(keepingCapacity: true)
            drainScheduled = false
        } else {
            chunk = Array(inbox[..<Self.maxFeedPerDrain])
            inbox.removeSubrange(..<Self.maxFeedPerDrain)
        }
        let more = drainScheduled
        inboxLock.unlock()
        if !chunk.isEmpty { tv?.feedKeepingSelection(chunk[...]) }
        // 一次只喂一段，剩余的留到下一轮 runloop：期间键盘/鼠标事件照常处理，大量输出也不冻结界面。
        if more { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }

    // MARK: C 回调（pump 线程）

    private static let onData: TermoSSHDataCallback = { ud, bytes, len in
        guard let ud, let bytes, len > 0 else { return }
        let driver = Unmanaged<SSHTerminalDriver>.fromOpaque(ud).takeUnretainedValue()
        driver.enqueue(UnsafeRawBufferPointer(start: bytes, count: Int(len)))
    }

    private static let onClosed: TermoSSHClosedCallback = { ud, code in
        guard let ud else { return }
        let driver = Unmanaged<SSHTerminalDriver>.fromOpaque(ud).takeRetainedValue()   // 平衡 connect 的 passRetained
        DispatchQueue.main.async { driver.reportClosed(code) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !data.isEmpty else { return }
        if shell == nil {
            if bufferEarlyInput, !closed, pendingInput.count + data.count <= Self.pendingInputCap {
                pendingInput.append(contentsOf: data)
            }
            return
        }
        write(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        wantedSize = (max(newCols, 1), max(newRows, 1))
        scheduleResize()
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
