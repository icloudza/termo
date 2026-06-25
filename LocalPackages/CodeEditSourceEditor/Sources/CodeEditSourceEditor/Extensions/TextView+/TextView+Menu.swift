//
//  TextView+Menu.swift
//  CodeEditSourceEditor
//
//  Created by Lukas Pistrol on 25.05.22.
//

// [termo] 原 setupMenus/helpMenu/codeMenu/gitMenu/removeMenus 全是死代码（全仓零调用点）：
//   - 上游插入的 9 个右键菜单项 action 全为 nil（点了无反应）；
//   - removeMenus 用 `if indexOfItem(withTitle:) >= 0`，而未命中返回的 NSNotFound(=NSIntegerMax) ≥ 0 为真，
//     一旦被调用就会以 NSNotFound 当下标调 removeItem(at:) → 抛 `index 9223372036854775807 is invalid`（定时炸弹）。
// 实际的编辑器右键菜单来自 CodeEditTextView 的 `TextView.menu(for:)` 覆写（已在 vendored 副本里汉化）。
// 故整段死代码删除，避免将来误接回触发上述崩溃。

import AppKit
