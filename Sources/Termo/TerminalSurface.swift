import SwiftTerm
import SwiftUI

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

        let copy = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = .command
        menu.addItem(copy)

        let paste = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        menu.addItem(paste)

        let selectAll = NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = .command
        menu.addItem(selectAll)

        menu.addItem(.separator())

        let clear = NSMenuItem(title: "清屏", action: #selector(TerminalActions.clearTerminal(_:)), keyEquivalent: "k")
        clear.keyEquivalentModifierMask = .command
        menu.addItem(clear)

        menu.addItem(.separator())

        let search = NSMenuItem(title: "搜索", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        search.keyEquivalentModifierMask = .command
        search.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        menu.addItem(search)

        return menu
    }
}

/// 监听终端的 OSC 7「当前目录变更」，把远端 cwd 回传给 AppModel（用于侧栏文件树定位）。
final class TerminalSessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
    var onCwd: ((String) -> Void)?
    var onTerminated: (() -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onTerminated?() }

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
