import AppKit
import SwiftTerm

/// 文本输入的标准编辑快捷键（⌘X / ⌘C / ⌘V / ⌘A / ⌘Z / ⌘⇧Z）：焦点在输入框、多行文本或代码编辑器时直接派发给它，
/// 不经主菜单。弹窗都在主窗口内，快捷键要先穿过窗口里整棵视图树、再到主菜单，任一环节被截走或菜单被换掉就全部失效。
/// 派发前按菜单的规则校验（密码框禁止复制、没有可撤销内容等），校验不过就放行，走原来的路径。
enum EditShortcuts {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command || mods == [.command, .shift],
              let window = event.window, window.isKeyWindow,
              let responder = window.firstResponder, isTextInput(responder),
              let action = action(for: event, shift: mods.contains(.shift)) else { return false }
        let probe = NSMenuItem(title: "", action: action, keyEquivalent: "")
        guard let target = NSApp.target(forAction: action, to: nil, from: probe) as AnyObject? else { return false }
        if let ok = target.validateMenuItem?(probe) {
            if !ok { return false }
        } else if let ok = target.validateUserInterfaceItem?(probe), !ok {
            return false
        }
        return NSApp.sendAction(action, to: target, from: probe)
    }

    /// 终端自己处理这些快捷键（见 PacedTerminalView），远程桌面要把按键原样发给远端，都不接管。
    private static func isTextInput(_ responder: NSResponder) -> Bool {
        if responder is TerminalView { return false }
        return responder is NSTextView || responder is NSTextInputClient
    }

    private static func action(for event: NSEvent, shift: Bool) -> Selector? {
        switch key(event) {
        case "z": return shift ? Selector(("redo:")) : Selector(("undo:"))
        case _ where shift: return nil
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        default: return nil
        }
    }

    /// 优先取按键字符（适配 Dvorak 等布局）；非 ASCII 布局（俄文等）退回物理键位。
    private static func key(_ event: NSEvent) -> String? {
        if let ch = event.charactersIgnoringModifiers?.lowercased(), ch.count == 1, ch.first?.isASCII == true {
            return ch
        }
        switch Int(event.keyCode) {
        case 7: return "x"
        case 8: return "c"
        case 9: return "v"
        case 0: return "a"
        case 6: return "z"
        default: return nil
        }
    }
}
