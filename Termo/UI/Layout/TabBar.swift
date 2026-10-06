import SwiftUI

struct TabBar: View {
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var frames: [Int: CGRect] = [:]   // 各标签 chip 在内容坐标系的位置，供“点击边缘标签露出相邻标签”

    var body: some View {
        let active = tabs.activeTabId.flatMap { frames[$0] }
        HStack(alignment: .center, spacing: 6) {
            TabStrip(
                newKey: tabs.tabs.count,
                activeKey: tabs.activeTabId ?? 0,
                activeMinX: active?.minX ?? 0,
                activeMaxX: active?.maxX ?? 0
            ) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        TabChip(tab: tab, model: model, tabs: tabs)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TabFramesKey.self,
                                                       value: [tab.id: g.frame(in: .named("tabstrip"))])
                            })
                    }
                }
                .coordinateSpace(name: "tabstrip")
                .onPreferenceChange(TabFramesKey.self) { frames = $0 }
            }
            if AppEnv.localTerminalEnabled {   // MAS 沙盒下隐藏本地终端入口
                NewTabButton { model.openLocalTerminal() }
                    .offset(y: -4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(maxWidth: .infinity)
        .background(Pal.mantle)
    }
}

/// 收集各标签 chip 在内容坐标系的布局框，供“点击边缘标签时滚动露出相邻标签”定位。
private struct TabFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TabChip: View {
    let tab: TabItem
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    private var symbol: String {
        switch tab.kind {
        case .overview: return "square.grid.2x2"
        case .terminal: return "terminal"
        case .files: return "folder"
        case .editor: return "doc.text"
        case .rdp: return "display"
        }
    }

    /// tab 图标：主机概览 tab 用该主机的发行版 logo（单色、不带品牌色）；其余用功能符号。
    @ViewBuilder
    private func tabIcon(active: Bool) -> some View {
        let fg = active ? Pal.text : Pal.overlay
        if tab.kind == .overview, let host = model.host(tab.hostId), let fontName = OSLogo.fontName,
           let logo = OSLogo.info(for: host.isRDP ? "windows" : (host.specs?.os ?? host.os)) {
            // 固定宽度：标签行宽度不足时图标不会被当成唯一柔性元素压扁（标题已 fixedSize、关闭按钮已定宽）。
            Text(logo.glyph).font(.custom(fontName, size: 12)).foregroundStyle(fg).frame(width: 12)
        } else {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(fg).frame(width: 12)
        }
    }

    /// 标题：同名编辑器标签（如两个 config）附上所在目录区分；过长从中间截断，完整标题放在悬停提示里。
    private var displayTitle: (text: String, truncated: Bool) {
        var t = tab.title
        if tab.kind == .editor,
           tabs.tabs.contains(where: { $0.id != tab.id && $0.kind == .editor && $0.title == tab.title }),
           let path = model.editorState(for: tab.id)?.file.path {
            let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !parent.isEmpty { t += " · " + parent }
        }
        let limit = 36
        guard t.count > limit else { return (t, false) }
        return (String(t.prefix(limit / 2)) + "…" + String(t.suffix(limit / 2 - 1)), true)
    }

    var body: some View {
        let active = tabs.activeTabId == tab.id
        let title = displayTitle
        HStack(spacing: 7) {
            tabIcon(active: active)
            Text(verbatim: title.text).font(.system(size: 12))
                .foregroundStyle(active ? Pal.text : Pal.subtext)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // 已在 displayTitle 里限长；超出由标签栏横向滚动
                .tooltip(tab.title, when: title.truncated)
            // 编辑器标签：未保存时显示圆点（hover 时让位给关闭按钮）
            if tab.kind == .editor, let st = model.editorState(for: tab.id) {
                EditorTabClose(state: st, hover: hover, active: active) { model.closeTab(tab.id) }
            } else {
                TabCloseButton { model.closeTab(tab.id) }
                    .opacity(active || hover ? 1 : 0)
            }
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
        .background(
            active ? Pal.fill(0.08) : (hover ? Pal.fill(0.04) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { hover = $0 }
        .pointerCursor()
        .accessibilityIdentifier(String(tab.id))
        .contextMenu {
            Button("关闭标签") { model.closeTab(tab.id) }
            Button("关闭其他标签") { model.closeOtherTabs(keep: tab.id) }
            Button("关闭右侧标签") { model.closeTabsToRight(of: tab.id) }
                .disabled(tabs.tabs.last?.id == tab.id)
            Button("关闭所有标签") { model.closeAllTabs() }
            Divider()
            Button("重命名…") { model.requestRenameTab(tab.id) }
        }
    }
}

/// 编辑器标签右侧：未保存→脏点，hover/已保存→关闭按钮。单独观察 EditorState 以保证脏态实时刷新。
private struct EditorTabClose: View {
    @ObservedObject var state: EditorState
    let hover: Bool
    let active: Bool
    let onClose: () -> Void

    var body: some View {
        ZStack {
            if state.isDirty && !hover {
                Circle().fill(Pal.yellow).frame(width: 7, height: 7).frame(width: 16, height: 16)
            } else {
                TabCloseButton(action: onClose)
                    .opacity(active || hover || state.isDirty ? 1 : 0)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// 标签关闭按钮：悬停在 ✕ 本身时才高亮（之前悬停整个标签就高亮，看不出点哪里）。
private struct TabCloseButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                .foregroundStyle(hover ? Pal.text : Pal.overlay)
                .frame(width: 18, height: 18)
                .background(hover ? Pal.fill(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .tooltip(String(localized: "关闭标签"))
    }
}

/// 标签栏右侧「新建本地终端」按钮。
private struct NewTabButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 13))
                .foregroundStyle(hover ? Pal.text : Pal.overlay)
                .frame(width: 26, height: 26)
                .background(hover ? Pal.fill(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .tooltip(String(localized: "新建本地终端（⌘T）"))
    }
}
