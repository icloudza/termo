import AppKit
import SwiftUI

struct Sidebar: View {
    @ObservedObject var model: AppModel
    // 切换 tab 时侧栏需重算（activeHostId 高亮、文件面板 sidebarFileTree），故一并观察 TabsModel。
    @ObservedObject var tabs: TabsModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var search = AppModel.shared.sidebarState   // 搜索词 / 脱敏开关
    @ObservedObject private var theme = ThemeManager.shared
    @FocusState private var searchFocused: Bool
    // 已折叠的分组名集合（仅本次运行有效，重启不保留）
    @State private var collapsedGroups: Set<String> = []

    private var filteredHosts: [Host] {
        // 「主机」面板只列 SSH 主机；RDP 主机归入 RDP 面板
        let sshHosts = model.hosts.filter { !$0.isRDP }
        guard !model.query.isEmpty else { return sshHosts }
        let q = model.query.lowercased()
        return sshHosts.filter {
            $0.name.lowercased().contains(q) || $0.addr.lowercased().contains(q)
        }
    }

    /// 分组名（保持出现顺序）。
    private static func orderedGroups(_ hosts: [Host]) -> [String] {
        var seen = Set<String>()
        return hosts.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sectionTitle).font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.text)
                Spacer()
                if model.section == .sshKeys {
                    SidebarHeaderButton(symbol: "square.and.arrow.down", tooltip: String(localized: "导入已有私钥")) {
                        model.presentImportKey()
                    }
                    SidebarHeaderButton(symbol: "plus", tooltip: String(localized: "生成新密钥")) { model.showGenerateKey = true }
                } else if model.section == .hosts {
                    SidebarHeaderButton(symbol: "plus", tooltip: String(localized: "添加主机")) { model.showAddHost = true }
                } else if model.section == .rdp {
                    SidebarHeaderButton(symbol: "plus", tooltip: String(localized: "添加 RDP 主机")) { model.showAddRDPHost = true }
                } else if model.section == .snippets {
                    SidebarHeaderButton(symbol: "plus", tooltip: String(localized: "新建片段")) { model.showCreateSnippet = true }
                }
            }
            .frame(height: 24)
            .padding(.leading, 14).padding(.trailing, 9)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if model.section == .hosts {
                Spacer().frame(height: 10)
                searchBox(privacy: true)
                let hosts = filteredHosts
                if hosts.isEmpty {
                    hostEmptyState
                } else {
                    ScrollView { hostList(hosts) }.padding(.top, 6)
                }
            } else if model.section == .files {
                filesPanel
            } else if model.section == .rdp {
                Spacer().frame(height: 10)
                searchBox(privacy: true)
                rdpPanel
            } else if model.section == .sshKeys {
                Spacer().frame(height: 10)
                searchBox(String(localized: "搜索密钥…"))
                KeysPanel(model: model)
            } else if model.section == .snippets {
                Spacer().frame(height: 10)
                searchBox(String(localized: "搜索片段…"))
                SnippetsPanel(model: model, tabs: tabs)
            }

            Spacer(minLength: 0)
            if AppEnv.localTerminalEnabled { localTerminalButton }   // MAS 沙盒下隐藏
        }
        .frame(width: max(LayoutModel.minExpanded, layout.sidebarWidth), alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Pal.mantle)
        .frame(width: layout.sidebarWidth, alignment: .leading)
        .clipped()
        .onChange(of: tabs.activeTabId) { _, _ in searchFocused = false }
        // 搜索词按分区各自生效：在「主机」里搜的词带到「密钥」会莫名其妙显示「无匹配密钥」。
        .onChange(of: model.section) { _, _ in if !search.query.isEmpty { search.query = "" } }
    }

    private var sectionTitle: String {
        switch model.section {
        case .hosts: return String(localized: "主机")
        case .files: return String(localized: "文件")
        case .sshKeys: return String(localized: "密钥")
        case .rdp: return "RDP"
        case .snippets: return String(localized: "代码片段")
        case .settings: return String(localized: "设置")
        }
    }

    private func searchBox(_ placeholder: String = String(localized: "搜索主机…"), privacy: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
            TextField(text: $search.query.singleLine, prompt: Text(placeholder).foregroundStyle(Pal.overlay)) { EmptyView() }
                .textFieldStyle(.plain)
                .lineLimit(1)
                .noNativeFocusRing()
                .font(.system(size: 13))
                .foregroundStyle(Pal.text)
                .focused($searchFocused)
                .onExitCommand { search.query = "" }     // Esc 清空搜索
                .modifier(DisabledUnderModal())
            if !search.query.isEmpty {
                Button { search.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .tooltip(String(localized: "清除搜索"))
            }
            // 脱敏开关：开启后隐藏列表/概览中的 IP、主机名（便于截图或共享屏幕）。只对主机类分区有意义。
            if privacy {
                Button { model.privacyMode.toggle() } label: {
                    Image(systemName: model.privacyMode ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(model.privacyMode ? Pal.mauve : Pal.overlay)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .tooltip(model.privacyMode ? String(localized: "显示真实信息") : String(localized: "脱敏显示(隐藏 IP / 主机名)"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(searchFocused ? Pal.mauve : Pal.fill(0.08), lineWidth: searchFocused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: searchFocused)
        .padding(.horizontal, 12)
    }

    /// 活动栏「文件」面板：有活动主机时显示其文件树，否则提示。
    @ViewBuilder
    private var filesPanel: some View {
        if let tree = model.sidebarFileTree {
            SidebarFileTree(state: tree.state, host: tree.host, model: model)
                .id(tree.id)
        } else {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(systemName: "folder").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text(filesPanelHint)
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
    }

    private var filesPanelHint: String {
        let host = model.host(model.activeHostId)
        if host?.isRDP == true { return String(localized: "远程桌面主机不支持文件浏览") }
        if model.activeTabId != nil && host == nil { return String(localized: "本地终端不在此显示文件") }
        return String(localized: "打开一个 SSH 主机后\n在此浏览文件")
    }

    /// 搜索时分组一律展开：命中的主机藏在折叠分组里等于没搜到。
    private func isCollapsed(_ group: String) -> Bool {
        model.query.isEmpty && collapsedGroups.contains(group)
    }

    /// 活动栏「RDP」面板：列出 RDP 主机（支持搜索），空时给出添加引导。
    @ViewBuilder
    private var rdpPanel: some View {
        let allRDP = model.hosts.filter { $0.isRDP }
        let q = model.query.lowercased()
        let rdpHosts = q.isEmpty ? allRDP
            : allRDP.filter { $0.name.lowercased().contains(q) || $0.addr.lowercased().contains(q) }

        if allRDP.isEmpty {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(systemName: "display").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("还没有 RDP 主机").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                TintedButton(title: "添加 RDP 主机") { model.showAddRDPHost = true }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        } else if rdpHosts.isEmpty {
            SearchNoMatch(text: String(localized: "无匹配主机"))
        } else {
            let rdpGroups = Self.orderedGroups(rdpHosts)
            let byGroup = Dictionary(grouping: rdpHosts, by: \.group)
            let activeId = model.activeHostId
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rdpGroups, id: \.self) { group in
                        groupHeader(group)
                        if !isCollapsed(group) {
                            ForEach(byGroup[group] ?? []) { host in
                                RDPHostRow(host: host, model: model, privacyMode: model.privacyMode,
                                           isActive: activeId == host.id)
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

    @ViewBuilder
    private var hostEmptyState: some View {
        // 只数 SSH 主机：只有 RDP 主机时这里也该是「还没有主机」+ 添加按钮，而不是「无匹配」。
        if model.hosts.contains(where: { !$0.isRDP }) {
            SearchNoMatch(text: String(localized: "无匹配主机"))
        } else {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(systemName: "server.rack").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("还没有主机").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                TintedButton(title: "添加主机") { model.showAddHost = true }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        }
    }

    private func hostList(_ hosts: [Host]) -> some View {
        let byGroup = Dictionary(grouping: hosts, by: \.group)
        let activeId = model.activeHostId
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.orderedGroups(hosts), id: \.self) { group in
                groupHeader(group)
                if !isCollapsed(group) {
                    ForEach(byGroup[group] ?? []) { host in
                        HostRow(host: host, model: model, privacyMode: model.privacyMode, isActive: activeId == host.id)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupHeader(_ group: String) -> some View {
        let collapsed = isCollapsed(group)
        return Button {
            if collapsed { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        } label: {
            HStack(spacing: 4) {
                // 折叠图标与分组名同字号等宽，展开向下、折叠向右
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 11)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(group.isEmpty ? String(localized: "未分组") : group)
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }

    private var localTerminalButton: some View {
        LocalTerminalButton { model.openLocalTerminal() }
    }
}

/// 侧栏底部「本地终端」入口。
private struct LocalTerminalButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .font(.system(size: 12)).foregroundStyle(Pal.mauve)
                    .frame(width: 22, height: 22)
                    .background(Pal.mauve.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                Text("本地终端").font(.system(size: 12)).foregroundStyle(hover ? Pal.text : Pal.subtext)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hover ? Pal.fill(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .padding(8)
    }
}

/// 侧栏标题栏右侧的图标按钮：24pt 点击区 + 悬停底色（原先只有字形本身能点）。
private struct SidebarHeaderButton: View {
    let symbol: String
    let tooltip: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "plus" ? 14 : 13))
                .foregroundStyle(Pal.mauve)
                .frame(width: 24, height: 24)
                .background(hover ? Pal.fill(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .tooltip(tooltip)
    }
}

/// 搜索无结果：显示搜索词并提供「清除搜索」，不让用户困在空列表里。主机、RDP、密钥、片段面板共用。
struct SearchNoMatch: View {
    let text: String
    @ObservedObject private var search = AppModel.shared.sidebarState

    var body: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text(text).font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text(verbatim: "“\(search.query)”")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .lineLimit(1).truncationMode(.middle)
            TintedButton(title: "清除搜索") { search.query = "" }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

/// 列表行只接收自己要显示的值，不订阅 AppModel：否则模型任何字段变化，每一行都要各自重算一遍。
struct HostRow: View {
    let host: Host
    let model: AppModel
    let privacyMode: Bool
    let isActive: Bool   // 由父级 Sidebar（观察 TabsModel）下传，确保切主机时高亮即时刷新
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        Button {
            model.openHost(host)
        } label: {
            HStack(spacing: 9) {
                HostLeadingIcon(host: host)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).font(.system(size: 13)).foregroundStyle(Pal.text)
                        .lineLimit(1).truncationMode(.tail)
                    Text(host.ipOrHost)
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1)
                        .privacyBlur(privacyMode)
                }
                Spacer(minLength: 4)
                // 延迟值统一右对齐到行末，多主机竖排时对齐整齐
                if host.status == .online, let ms = host.latencyMs {
                    Text("\(ms) ms").font(.system(size: 11)).foregroundStyle(LatencyLevel(ms: ms).color)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(
                isActive ? Pal.mauve.opacity(0.15) : (hover ? Pal.fill(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .animation(.easeOut(duration: 0.18), value: isActive)   // 选中高亮丝滑淡入淡出
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .contextMenu {
            Button("打开终端") { model.openHostTerminal(host) }
            Button("新建终端") { model.openHostTerminal(host, forceNew: true) }
            Button("打开文件") { model.openHostFiles(host) }
            Button("编辑主机") { model.beginEditHost(host) }
            Button("复制地址") { copyToPasteboard(host.ipOrHost) }
            Divider()
            Button("删除主机", role: .destructive) { model.requestDeleteHost(host) }
        }
    }
}

/// RDP 主机行：点击连接远程桌面。
struct RDPHostRow: View {
    let host: Host
    let model: AppModel
    let privacyMode: Bool
    let isActive: Bool   // 同 HostRow：由 Sidebar 下传以即时刷新高亮
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        Button {
            model.openHost(host)   // 与 SSH 主机一致：先进概览页，由概览里的「远程桌面」再发起连接
        } label: {
            HStack(spacing: 9) {
                HostLeadingIcon(host: host)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).font(.system(size: 13)).foregroundStyle(Pal.text)
                        .lineLimit(1).truncationMode(.tail)
                    Text(host.ipOrHost)
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1)
                        .privacyBlur(privacyMode)
                }
                Spacer(minLength: 4)
                if host.status == .online, let ms = host.latencyMs {
                    Text("\(ms) ms").font(.system(size: 11)).foregroundStyle(LatencyLevel(ms: ms).color)
                } else {
                    Image(systemName: "display").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(
                isActive ? Pal.mauve.opacity(0.15) : (hover ? Pal.fill(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .animation(.easeOut(duration: 0.18), value: isActive)   // 选中高亮丝滑淡入淡出
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .contextMenu {
            Button("远程桌面") { model.openHostRDP(host) }
            Button("编辑主机") { model.editingRDPHost = host }
            Button("复制地址") { copyToPasteboard(host.ipOrHost) }
            Divider()
            Button("删除主机", role: .destructive) { model.requestDeleteHost(host) }
        }
    }
}

/// 有弹窗时禁用：弹窗是窗口内叠层，按 Tab 会把焦点移到背后的搜索框，之后敲的字都进了看不见的搜索框。
private struct DisabledUnderModal: ViewModifier {
    @ObservedObject private var dialogs = AppModel.shared.dialogs
    func body(content: Content) -> some View { content.disabled(dialogs.isModalPresented) }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
