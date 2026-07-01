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
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

struct TerminalSurface: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    var isActive: Bool = true     // tab 是否为当前活动 tab（keep-alive 下所有终端常驻，靠这个区分）

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminal.menu = Self.buildContextMenu()
        terminal.isHidden = !isActive
        // 只让活动终端首次创建时抢焦点；非活动的不抢（keep-alive 下会同时创建多个，避免互相抢）。
        if isActive {
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 非活动终端 isHidden=true：AppKit 跳过其 draw（比 opacity=0 省），避免 N 个高吞吐后台终端
        // 叠加离屏重绘的 CPU；进程/PTY 照常运行、输出继续进 SwiftTerm 缓冲。隐藏视图也会自动放弃 first
        // responder（焦点安全）。切到终端的聚焦由 AppModel.focusActiveTab 显式处理 —— 不在此 makeFirstResponder：
        // updateNSView 会随主题/设置/hover 任意重绘频繁触发，在此抢焦点会把键盘从侧栏搜索框抢回终端。
        if nsView.isHidden == isActive { nsView.isHidden = !isActive }
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

/// 单个 SSH 终端标签的连接态：用于断线时保留标签并展示重连覆盖层。本地终端不创建。
@MainActor
final class TerminalConn: ObservableObject {
    enum Phase { case live, dropped }
    @Published var phase: Phase = .live
    var attempt = 0    // 连续重连失败的退避代数，连上后清零
    var dropGen = 0    // 掉线代数，供看门狗判断某次重连尝试期间是否又掉线
}

/// 终端断线覆盖层：连接断开时盖在终端之上，显示重连状态与「立即重连」入口；连接正常时不渲染。
struct TerminalReconnectOverlay: View {
    @ObservedObject var conn: TerminalConn
    let onReconnect: () -> Void

    var body: some View {
        if conn.phase == .dropped {
            ZStack {
                Pal.base.opacity(0.55)
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(Pal.yellow)
                    Text("连接已断开").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在重连…").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    }
                    Button(action: onReconnect) {
                        Text("立即重连").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.mauve)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
                .padding(24)
                .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            }
            .transition(.opacity)
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
    func clearTerminal(_ sender: Any?) {
        let terminal = getTerminal()
        terminal.feed(text: "\u{0C}")
        terminal.resetToInitialState()
    }
}

/// 终端视图子类：重写粘贴，根治「粘贴长命令/脚本被截断、错行无法运行」这一终端通病。
/// SwiftTerm 原生 paste 把整块一次性灌进 PTY；远端 tty 的输入队列（MAX_INPUT / 行规范 MAX_CANON，约 1–4KB）
/// 会被瞬间灌爆 —— 远端 shell 逐行消费跟不上进来的字节速率，于是丢字节、行坍塌（即你看到的粘贴乱掉）。
/// 三招根治：① 换行归一；② 括号粘贴包裹（远端开启 2004 时整块当字面量、不逐行抢跑）；③ 分片 + 片间限速，给远端留出消费时间。
final class PacedTerminalView: LocalProcessTerminalView {
    private static let chunkSize = 1024          // 单片字节数：稳在常见 tty 输入缓冲之下
    private static let interChunkDelay = 0.012   // 片间延时(s)：~1KB/12ms ≈ 85KB/s，够快又不灌爆

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
