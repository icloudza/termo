import SwiftTerm
import SwiftUI

struct TerminalSurface: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminal.menu = Self.buildContextMenu()
        DispatchQueue.main.async {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
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
