import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// 终端拖放区：外部文件拖入 → 上传到该终端的当前目录（OSC7 跟踪的 cwd）。
/// 拖拽悬停时叠加蓝色边框、透明填充的反馈层（仅 SSH 终端可上传；本地终端不接管拖放）。
struct TerminalDropArea: View {
    let terminal: LocalProcessTerminalView
    let isActive: Bool
    let model: AppModel
    let tabId: Int
    let canUpload: Bool
    @State private var targeted = false

    private static let dropBlue = Color(hex: 0x1E90FF)   // 同编辑器改动竖条蓝

    var body: some View {
        TerminalSurface(terminal: terminal, isActive: isActive)
            .overlay { if targeted { dropOverlay } }
            .animation(.easeOut(duration: 0.12), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: canUpload ? $targeted : nil) { providers in
                guard canUpload else { return false }
                loadURLs(providers) { urls in
                    if !urls.isEmpty { model.uploadDroppedFiles(urls, toTabId: tabId) }
                }
                return true
            }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Self.dropBlue.opacity(0.07))   // 内容透明、终端可见
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.dropBlue, lineWidth: 2))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 22, weight: .medium))
                    Text("松开以上传到当前目录").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Self.dropBlue)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Pal.solidMantle.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func loadURLs(_ providers: [NSItemProvider], _ completion: @escaping ([URL]) -> Void) {
        loadDroppedFileURLs(providers, completion)
    }
}

struct TerminalSurface: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    var isActive: Bool = true     // tab 是否为当前活动 tab（keep-alive 下所有终端常驻，靠这个区分）

    func makeNSView(context: Context) -> TerminalHostView {
        terminal.menu = Self.buildContextMenu()
        terminal.isHidden = !isActive
        let host = TerminalHostView(terminal: terminal)
        // 只让活动终端首次创建时抢焦点；非活动的不抢（keep-alive 下会同时创建多个，避免互相抢）。
        if isActive {
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        return host
    }

    func updateNSView(_ nsView: TerminalHostView, context: Context) {
        // 非活动终端 isHidden=true：AppKit 跳过其 draw（比 opacity=0 省），避免 N 个高吞吐后台终端
        // 叠加离屏重绘的 CPU；进程/PTY 照常运行、输出继续进 SwiftTerm 缓冲。隐藏视图也会自动放弃 first
        // responder（焦点安全）。切到终端的聚焦由 AppModel.focusActiveTab 显式处理 —— 不在此 makeFirstResponder：
        // updateNSView 会随主题/设置/hover 任意重绘频繁触发，在此抢焦点会把键盘从侧栏搜索框抢回终端。
        if terminal.isHidden == isActive { terminal.isHidden = !isActive }
    }

    private static func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let copy = NSMenuItem(title: String(localized: "复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = .command
        menu.addItem(copy)

        let paste = NSMenuItem(title: String(localized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        menu.addItem(paste)

        let selectAll = NSMenuItem(title: String(localized: "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = .command
        menu.addItem(selectAll)

        menu.addItem(.separator())

        let clear = NSMenuItem(title: String(localized: "清屏"), action: #selector(TerminalActions.clearTerminal(_:)), keyEquivalent: "k")
        clear.keyEquivalentModifierMask = .command
        menu.addItem(clear)

        menu.addItem(.separator())

        let search = NSMenuItem(title: String(localized: "搜索"), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        search.keyEquivalentModifierMask = .command
        search.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        menu.addItem(search)

        return menu
    }
}

/// 终端的布局宿主：SwiftUI 只改它的尺寸，由它决定何时把尺寸交给终端。
/// 终端改尺寸 = 整个缓冲区 reflow + 全屏重绘 + 远端 window-change，远比一帧布局贵：
/// - 窗口拖拽缩放期间（inLiveResize）终端保持原尺寸，松手后一次性改到位；
/// - 其它连续变化（侧栏松手动画逐帧改宽等）首帧立即生效，其余合并到末尾再改一次。
final class TerminalHostView: NSView {
    private let terminal: NSView
    private var lastApply: CFTimeInterval = 0
    private var trailingScheduled = false
    private static let burstWindow: CFTimeInterval = 0.05

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(frame: .zero)
        clipsToBounds = true                     // macOS 14 起默认不裁剪；推迟改尺寸期间终端可能比宿主大
        terminal.autoresizingMask = []
        terminal.translatesAutoresizingMaskIntoConstraints = true
        addSubview(terminal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeTerminal()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {}   // 子视图尺寸完全由 sizeTerminal 接管

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        applyNow()
    }

    private func sizeTerminal() {
        if inLiveResize { pin(); return }
        if CACurrentMediaTime() - lastApply < Self.burstWindow {
            pin()
            if !trailingScheduled {
                trailingScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstWindow + 0.01) { [weak self] in
                    self?.trailingScheduled = false
                    self?.sizeTerminal()
                }
            }
            return
        }
        applyNow()
    }

    private func applyNow() {
        guard bounds.width > 1, bounds.height > 1 else { return }   // 尚未布局：0 尺寸会把终端压成 1 列并同步给远端
        lastApply = CACurrentMediaTime()
        let target = NSRect(origin: .zero, size: bounds.size)
        if terminal.frame != target { terminal.frame = target }
    }

    /// 暂不改终端尺寸、只挪位置：比宿主高时贴底（光标所在的底部几行保持可见），否则贴顶。
    private func pin() {
        let h = terminal.frame.height
        let origin = NSPoint(x: 0, y: h > bounds.height ? bounds.height - h : 0)
        if terminal.frame.origin != origin { terminal.setFrameOrigin(origin) }
    }
}

extension TerminalView {
    /// 喂入远端输出且不打断用户的鼠标选区。
    /// SwiftTerm 在 allowMouseReporting 为真时，**每次**输出（feedPrepare / linefeed）都会清掉选区：
    /// 拖选到一半选区被重置成从当前位置重新起选（像「失焦断开」），选区没了 ⌘C 菜单项也随之禁用（复制失效）。
    /// 只有远端程序真的开启了鼠标上报（vim mouse=a、tmux mouse on 等）才需要把鼠标交给它，此时才保持 SwiftTerm 原行为。
    func feedKeepingSelection(_ bytes: ArraySlice<UInt8>) {
        let term = getTerminal()
        allowMouseReporting = term.mouseMode != .off
        feed(byteArray: bytes)
        allowMouseReporting = term.mouseMode != .off   // 本批输出可能刚开/关了鼠标上报
    }
}

/// 单个 SSH 终端标签的连接态：用于断线时保留标签并展示重连覆盖层。本地终端不创建。
@MainActor
final class TerminalConn: ObservableObject {
    enum Phase { case live, dropped }
    /// 掉线后的处境，覆盖层据此如实显示（之前一律「正在重连…」，离线、等待退避时也在转圈）。
    enum Status: Equatable {
        case waitingNetwork          // 离线：等网络恢复后自动重连
        case retrying(at: Date)      // 退避中：到点自动重连
        case connecting              // 正在重连
        case failed(String)          // 认证 / 指纹等重试也没用的错误：不再自动重试
    }
    @Published var phase: Phase = .live
    @Published var status: Status = .connecting
    var attempt = 0    // 连续重连失败的退避代数，连上后清零
    var dropGen = 0    // 掉线代数
    var lastError: String?
}

/// 终端断线覆盖层：连接断开时盖在终端之上，如实显示重连状态，提供「立即重连」「关闭标签」；连接正常时不渲染。
struct TerminalReconnectOverlay: View {
    @ObservedObject var conn: TerminalConn
    let onReconnect: () -> Void
    let onClose: () -> Void

    var body: some View {
        if conn.phase == .dropped {
            ZStack {
                Pal.base.opacity(0.55).contentShape(Rectangle())
                VStack(spacing: 12) {
                    Image(systemName: icon).font(.system(size: 28)).foregroundStyle(iconColor)
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    detail
                    HStack(spacing: 10) {
                        SecondaryButton(title: "关闭标签", action: onClose)
                        PrimaryButton(title: "立即重连", enabled: canRetryNow, action: onReconnect)
                    }
                    .padding(.top, 2)
                }
                .padding(24)
                .frame(maxWidth: 380)
                .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.fill(0.08), lineWidth: 1))
            }
            .transition(.opacity)
        }
    }

    private var icon: String {
        switch conn.status {
        case .waitingNetwork: return "wifi.slash"
        case .failed: return "exclamationmark.triangle"
        default: return "wifi.exclamationmark"
        }
    }

    private var iconColor: SwiftUI.Color {
        if case .failed = conn.status { return Pal.red }
        return Pal.yellow
    }

    private var title: String {
        if case .failed = conn.status { return String(localized: "重新连接失败") }
        return String(localized: "连接已断开")
    }

    private var canRetryNow: Bool { conn.status != .connecting }

    @ViewBuilder
    private var detail: some View {
        switch conn.status {
        case .waitingNetwork:
            Text("网络已断开，恢复后自动重连").font(.system(size: 12)).foregroundStyle(Pal.subtext)
        case .connecting:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在重连…").font(.system(size: 12)).foregroundStyle(Pal.subtext)
            }
        case .retrying(let at):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(1, Int(at.timeIntervalSince(ctx.date).rounded(.up)))
                Text("\(s) 秒后自动重连").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .monospacedDigit()
            }
        case .failed(let msg):
            Text(msg).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .multilineTextAlignment(.center).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 监听终端的 OSC 7「当前目录变更」，把远端 cwd 回传给 AppModel（用于侧栏文件树定位）。
final class TerminalSessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
    var onCwd: ((String) -> Void)?
    var onTerminated: ((Int32?) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onTerminated?(exitCode) }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let p = Self.parsePath(directory) else { return }
        onCwd?(p)
    }

    /// 把 OSC 7 的 `file://host/path` 解析为绝对路径。
    static func parsePath(_ dir: String?) -> String? {
        guard let dir else { return nil }
        if dir.hasPrefix("file://") {
            let after = dir.dropFirst("file://".count)   // "host/path" 或 "/path"
            if let slash = after.firstIndex(of: "/") { return String(after[slash...]) }
            return nil
        }
        return dir.hasPrefix("/") ? dir : nil
    }
}

@objc protocol TerminalActions {
    func clearTerminal(_ sender: Any?)
}

extension LocalProcessTerminalView: TerminalActions {
    /// ⌘K 清屏：清掉屏幕和回滚区，只保留光标所在的提示符行并把它移到顶部（同 VS Code / iTerm2）。
    /// 只改本地显示、不发给远端；不做整机复位，否则键盘、鼠标、括号粘贴等模式被重置，vim/tmux 里会错乱。
    /// 全屏程序（vim、htop 等备用屏）里不动。
    func clearTerminal(_ sender: Any?) {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        let row = terminal.getCursorLocation().y
        var seq = row > 0 ? "\u{1b}[\(row)S\u{1b}[\(row)A" : ""
        seq += "\u{1b}[3J"
        feed(text: seq)
    }
}

/// 终端视图子类：重写粘贴，根治「粘贴长命令/脚本被截断、错行无法运行」这一终端通病。
/// SwiftTerm 原生 paste 把整块一次性灌进 PTY；远端 tty 的输入队列（MAX_INPUT / 行规范 MAX_CANON，约 1–4KB）
/// 会被瞬间灌爆 —— 远端 shell 逐行消费跟不上进来的字节速率，于是丢字节、行坍塌（即你看到的粘贴乱掉）。
/// 三招根治：① 换行归一；② 括号粘贴包裹（远端开启 2004 时整块当字面量、不逐行抢跑）；③ 分片 + 片间限速，给远端留出消费时间。
final class PacedTerminalView: LocalProcessTerminalView {
    private static let chunkSize = 1024          // 单片字节数：稳在常见 tty 输入缓冲之下
    private static let interChunkDelay = 0.012   // 片间延时(s)：~1KB/12ms ≈ 85KB/s，够快又不灌爆

    override func dataReceived(slice: ArraySlice<UInt8>) {
        feedKeepingSelection(slice)
    }

    /// 终端为第一响应者时直接处理 ⌘C/⌘V/⌘A/⌘K/⌘F，不依赖主菜单把快捷键路由过来：
    /// 主菜单由 SwiftUI 管理、可能被替换，且「复制」项靠选区校验启用，任一环节出问题快捷键就整体失效。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
        switch Self.shortcutKey(event) {
        case "c":
            if selectionActive { copy(self) }     // 无选区时吞掉，不清空剪贴板
            return true
        case "v":
            paste(self)
            return true
        case "a":
            selectAll(self)
            return true
        case "k":
            clearTerminal(self)
            return true
        case "f":
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(item)
            return true
        default:
            return false
        }
    }

    /// 快捷键字母：优先取按键字符（适配 Dvorak 等布局）；非 ASCII 布局（俄文等）退回物理键位。
    private static func shortcutKey(_ event: NSEvent) -> String? {
        if let ch = event.charactersIgnoringModifiers?.lowercased(), ch.count == 1, ch.first?.isASCII == true {
            return ch
        }
        switch Int(event.keyCode) {
        case 8: return "c"
        case 9: return "v"
        case 0: return "a"
        case 40: return "k"
        case 3: return "f"
        default: return nil
        }
    }

    override func paste(_ sender: Any) {
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }
        // 换行归一：\r\n / 残留 \r → \n。否则 cooked 模式下 ICRNL 把 CR 也当回车，CR+LF 会触发双重提交（多跑一次空命令）。
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let content = Array(text.utf8)

        // 把内容切成片；括号粘贴的 start/end 标记**贴附**到首片头、末片尾——
        // 标记与相邻内容同处一次 send，绝不单独发、绝不被切片切开 ⟹ 顺序天然正确，不会泄漏成可见字符（如末尾 ESC[201~ 残字）。
        var chunks: [[UInt8]] = []
        var i = 0
        while i < content.count {
            let end = min(i + Self.chunkSize, content.count)
            chunks.append(Array(content[i..<end]))
            i = end
        }
        if chunks.isEmpty { chunks.append([]) }   // 内容理论非空，保险

        if getTerminal().bracketedPasteMode {
            chunks[0].insert(contentsOf: EscapeSequences.bracketedPasteStart, at: 0)
            chunks[chunks.count - 1].append(contentsOf: EscapeSequences.bracketedPasteEnd)
        }
        sendChunks(chunks, from: 0)
    }

    /// 逐片限速发送：每片 chunkSize 字节，片间隔 interChunkDelay；主线程链式调度，保持提交顺序、不阻塞 UI。
    /// 小粘贴（单片）即时发完、无延迟；仅大块才进入限速节奏。
    private func sendChunks(_ chunks: [[UInt8]], from i: Int) {
        guard i < chunks.count else { return }
        // 经 terminalDelegate 发送：本地终端 delegate=self→本地进程，SSH 终端 delegate=驱动→libssh2 通道。
        terminalDelegate?.send(source: self, data: chunks[i][...])
        guard i + 1 < chunks.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.interChunkDelay) { [weak self] in
            self?.sendChunks(chunks, from: i + 1)
        }
    }
}
