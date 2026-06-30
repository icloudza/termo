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
                Button {
                    model.openLocalTerminal()
                } label: {
                    Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                        .frame(width: 24, height: 34)
                        .offset(y: -5)
                }
                .buttonStyle(.plain)
                .pointerCursor()
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

    var body: some View {
        let active = tabs.activeTabId == tab.id
        HStack(spacing: 7) {
            tabIcon(active: active)
            Text(tab.title).font(.system(size: 12))
                .foregroundStyle(active ? Pal.text : Pal.subtext)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // 不截断；超出由标签栏横向滚动
            // 编辑器标签：未保存时显示圆点（hover 时让位给关闭按钮）
            if tab.kind == .editor, let st = model.editorState(for: tab.id) {
                EditorTabClose(state: st, hover: hover, active: active) { model.closeTab(tab.id) }
            } else {
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 16, height: 16)
                        .background(
                            hover ? Pal.fill(0.1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
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
            Button { model.closeTab(tab.id) } label: { Label("关闭当前", systemImage: "xmark") }
            Button { model.closeOtherTabs(keep: tab.id) } label: { Label("关闭其他", systemImage: "xmark.circle") }
            Button { model.closeAllTabs() } label: { Label("关闭所有", systemImage: "xmark.octagon") }
            Divider()
            Button { model.requestRenameTab(tab.id) } label: { Label("重命名", systemImage: "pencil") }
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
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 16, height: 16)
                        .background(hover ? Pal.fill(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .opacity(active || hover || state.isDirty ? 1 : 0)
            }
        }
        .frame(width: 16, height: 16)
    }
}
