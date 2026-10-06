import SwiftUI

/// 「代码片段」活动栏分区的侧栏面板：按分组（可折叠）列出片段，支持搜索、运行/插入到当前终端、编辑。
/// 观察 TabsModel 以便「是否有可运行终端」随标签切换即时刷新。
struct SnippetsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var search = AppModel.shared.sidebarState   // 搜索词变化时刷新列表
    @ObservedObject private var theme = ThemeManager.shared
    @State private var collapsedGroups: Set<String> = []   // 本次运行内有效，重启不保留（同主机侧栏）

    private var filtered: [Snippet] {
        let q = model.query.lowercased()
        guard !q.isEmpty else { return model.snippets }
        return model.snippets.filter {
            $0.name.lowercased().contains(q)
                || $0.content.lowercased().contains(q)
                || $0.displayGroup.lowercased().contains(q)
        }
    }

    /// 出现过的分组名（保序，按片段顺序）。
    private var groups: [String] {
        var seen: [String] = []
        for s in filtered where !seen.contains(s.displayGroup) { seen.append(s.displayGroup) }
        return seen
    }

    var body: some View {
        if model.snippets.isEmpty {
            emptyState
        } else if filtered.isEmpty {
            SearchNoMatch(text: String(localized: "无匹配片段"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups, id: \.self) { group in
                        groupHeader(group)
                        if !isCollapsed(group) {
                            ForEach(filtered.filter { $0.displayGroup == group }) { s in
                                SnippetRow(snippet: s, model: model, canRun: model.hasSnippetTarget)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 搜索时分组一律展开，命中项不会藏在折叠分组里。
    private func isCollapsed(_ group: String) -> Bool {
        model.query.isEmpty && collapsedGroups.contains(group)
    }

    private func groupHeader(_ group: String) -> some View {
        let collapsed = isCollapsed(group)
        return Button {
            if collapsed { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 11)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(group).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text("还没有代码片段").font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("把常用命令存成片段，一键发到终端").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            TintedButton(title: "新建片段") { model.showCreateSnippet = true }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

/// 片段行：单击编辑，悬停 ▶ 运行到当前终端，右键含运行/插入/复制/编辑/删除。
private struct SnippetRow: View {
    let snippet: Snippet
    let model: AppModel          // 只在动作里用，不订阅：模型任何变化不再让每一行重算
    let canRun: Bool
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    private var hasVars: Bool { !Snippet.variableNames(in: snippet.content).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            // 左侧整块是「编辑」按钮；▶ 是并列的独立按钮（不嵌套、不挂手势），两者互不等待。
            Button { model.editingSnippet = snippet } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12)).foregroundStyle(Pal.mauve).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(snippet.name).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                            if hasVars {
                                Image(systemName: "curlybraces").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                                    .tooltip(String(localized: "含 {{变量}}，运行时填值"))
                            }
                        }
                        Text(snippet.preview)
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            if hover && canRun {
                Button { model.triggerSnippet(snippet) } label: {
                    Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(Pal.mauve)
                        .frame(width: 22, height: 22)
                        .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().tooltip(String(localized: "使用片段"))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(hover ? Pal.fill(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // 行本身不挂点击手势：之前的双击手势会和 ▶ 按钮的单击落在同一手势竞技场里互相等待，
        // 导致「点 ▶ 没反应/延迟、询问弹窗迟迟不出」。运行统一走 ▶ 按钮与右键菜单，单击即时响应。
        .contextMenu {
            Button("运行到当前终端") { model.sendSnippet(snippet, run: true) }.disabled(!canRun)
            Button("插入到当前终端") { model.sendSnippet(snippet, run: false) }.disabled(!canRun)
            Button("复制正文") { model.copySnippet(snippet) }
            Button("编辑") { model.editingSnippet = snippet }
            Divider()
            Button("删除", role: .destructive) { model.requestDeleteSnippet(snippet) }
        }
    }
}
