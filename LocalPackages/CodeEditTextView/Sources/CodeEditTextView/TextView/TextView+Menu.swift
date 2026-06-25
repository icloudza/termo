//
//  TextView+Menu.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    override public func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }

        // [termo vendored 汉化] 上游写死英文 Cut/Copy/Paste；改中文 + 补「全选」。
        // selector 是 TextView 自身的 cut/copy/paste/selectAll，target=nil 经响应链命中。
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = .command
            return menuItem
        }
        menu.items = [
            item("剪切", #selector(cut(_:)), "x"),
            item("拷贝", #selector(copy(_:)), "c"),
            item("粘贴", #selector(paste(_:)), "v"),
            .separator(),
            item("全选", #selector(selectAll(_:)), "a")
        ]

        return menu
    }

    // [termo vendored] AppKit 会在文本视图右键菜单上自动追加英文「AutoFill / Services / Share」等子菜单项，
    // 无法本地化。我们的菜单是扁平的（无子菜单），故在菜单弹出前剔除所有「带子菜单的项」=系统注入项，
    // 并清理因此遗留的尾部分隔符 → 只留剪切/拷贝/粘贴/全选的纯中文菜单。
    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // AutoFill 的子菜单是懒加载的，willOpenMenu 时 submenu 还是 nil，无法靠 submenu 判别。
        // 改为「只保留我们自己加的 4 个动作（剪切/拷贝/粘贴/全选）+ 分隔符」，其余系统注入项一律删。
        let allowed: Set<Selector> = [
            #selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
            #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))
        ]
        for menuItem in menu.items where !menuItem.isSeparatorItem {
            if let action = menuItem.action, allowed.contains(action) { continue }
            menu.removeItem(menuItem)
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}
