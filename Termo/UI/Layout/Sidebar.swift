import SwiftUI

struct Sidebar: View {
    @ObservedObject var model: AppModel
    // 切换 tab 时侧栏需重算（activeHostId 高亮、文件面板 sidebarFileTree），故一并观察 TabsModel。
    @ObservedObject var tabs: TabsModel
    @ObservedObject var layout: LayoutModel
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

    private var groups: [String] {
        var seen: [String] = []
        for h in filteredHosts where !seen.contains(h.group) { seen.append(h.group) }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sectionTitle).font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.text)
                Spacer()
                if model.section == .sshKeys {
                    Button { model.presentImportKey() } label: {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 13)).foregroundStyle(Pal.mauve)
                    }
                    .buttonStyle(.plain).pointerCursor().help("导入已有私钥")
                    Button { model.showGenerateKey = true } label: {
                        Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(Pal.mauve)
                    }
                    .buttonStyle(.plain).pointerCursor().help("生成新密钥")
                } else if model.section == .hosts || model.section == .rdp {
                    Button {
                        if model.section == .rdp { model.showAddRDPHost = true }
                        else { model.showAddHost = true }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(Pal.mauve)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                } else if model.section == .snippets {
                    Button { model.showCreateSnippet = true } label: {
                        Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(Pal.mauve)
                    }
                    .buttonStyle(.plain).pointerCursor().help("新建片段")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if model.section == .hosts {
                Spacer().frame(height: 10)
                searchBox()
                if filteredHosts.isEmpty {
                    hostEmptyState
                } else {
                    ScrollView { hostList }.padding(.top, 6)
                }
            } else if model.section == .files {
                filesPanel
            } else if model.section == .rdp {
                Spacer().frame(height: 10)
                searchBox()
                rdpPanel
            } else if model.section == .sshKeys {
                Spacer().frame(height: 10)
                searchBox("搜索密钥…")
                KeysPanel(model: model)
            } else if model.section == .snippets {
                Spacer().frame(height: 10)
                searchBox("搜索片段…")
                SnippetsPanel(model: model, tabs: tabs)
            } else {
                Spacer()
                Text("\(sectionTitle)模块开发中")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }

            Spacer(minLength: 0)
            localTerminalButton
        }
        .frame(width: max(224, layout.sidebarWidth), alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Pal.mantle)
        .frame(width: layout.sidebarWidth, alignment: .leading)
        .clipped()
        .onChange(of: tabs.activeTabId) { _ in searchFocused = false }
    }

    private var sectionTitle: String {
        switch model.section {
        case .hosts: return "主机"
        case .files: return "文件"
        case .sshKeys: return "密钥"
        case .rdp: return "RDP"
        case .snippets: return "代码片段"
        case .settings: return "设置"
        }
    }

    private func searchBox(_ placeholder: String = "搜索主机…") -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Pal.text)
                .focused($searchFocused)
            // 脱敏开关：开启后隐藏列表/概览中的 IP、主机名（便于截图或共享屏幕）。
            Button { model.privacyMode.toggle() } label: {
                Image(systemName: model.privacyMode ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(model.privacyMode ? Pal.mauve : Pal.overlay)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(model.privacyMode ? "显示真实信息" : "脱敏显示(隐藏 IP / 主机名)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
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
                Spacer()
                Image(systemName: "folder").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("打开一个主机后\n在此浏览文件")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
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
                Button { model.showAddRDPHost = true } label: {
                    Text("添加 RDP 主机").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
        } else if rdpHosts.isEmpty {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("无匹配主机").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {   // 与 SSH 主机列表(hostList)行间距一致
                    ForEach(rdpHosts) { host in
                        RDPHostRow(host: host, model: model, isActive: model.activeHostId == host.id)
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
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: model.hosts.isEmpty ? "server.rack" : "magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text(model.hosts.isEmpty ? "还没有主机" : "无匹配主机")
                .font(.system(size: 13)).foregroundStyle(Pal.subtext)
            if model.hosts.isEmpty {
                Button { model.showAddHost = true } label: {
                    Text("添加主机").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groups, id: \.self) { group in
                groupHeader(group)
                if !collapsedGroups.contains(group) {
                    ForEach(filteredHosts.filter { $0.group == group }) { host in
                        HostRow(host: host, model: model, isActive: model.activeHostId == host.id)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupHeader(_ group: String) -> some View {
        let collapsed = collapsedGroups.contains(group)
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
                Text(group)
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
        Button {
            model.openLocalTerminal()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .font(.system(size: 12)).foregroundStyle(Pal.mauve)
                    .frame(width: 22, height: 22)
                    .background(Pal.mauve.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                Text("本地终端").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(8)
    }
}

struct HostRow: View {
    let host: Host
    @ObservedObject var model: AppModel
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
                    Text(host.ipOrHost)
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1)
                        .privacyBlur(model.privacyMode)
                }
                Spacer()
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
            Divider()
            Button("删除主机", role: .destructive) { model.requestDeleteHost(host) }
        }
    }
}

/// RDP 主机行：点击连接远程桌面。
struct RDPHostRow: View {
    let host: Host
    @ObservedObject var model: AppModel
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
                    Text(host.ipOrHost)
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1)
                        .privacyBlur(model.privacyMode)
                }
                Spacer()
                Image(systemName: "display").font(.system(size: 11)).foregroundStyle(Pal.overlay)
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
            Divider()
            Button("删除主机", role: .destructive) { model.requestDeleteHost(host) }
        }
    }
}
