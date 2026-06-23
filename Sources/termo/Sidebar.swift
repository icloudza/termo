import SwiftUI

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @FocusState private var searchFocused: Bool

    private var filteredHosts: [Host] {
        guard !model.query.isEmpty else { return model.hosts }
        let q = model.query.lowercased()
        return model.hosts.filter {
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
                if model.section == .hosts {
                    Button {
                        model.showAddHost = true
                    } label: {
                        Image(systemName: "plus").font(.system(size: 14)).foregroundStyle(Pal.mauve)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 10)

            if model.section == .hosts {
                Spacer().frame(height: 8)
                searchBox
                if filteredHosts.isEmpty {
                    hostEmptyState
                } else {
                    ScrollView { hostList }.padding(.top, 6)
                }
            } else if model.section == .files {
                filesPanel
            } else {
                Spacer()
                Text("\(sectionTitle)模块开发中")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }

            Spacer(minLength: 0)
            localTerminalButton
        }
        .frame(width: max(224, model.sidebarWidth), alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Pal.mantle)
        .frame(width: model.sidebarWidth, alignment: .leading)
        .clipped()
        .onChange(of: model.activeTabId) { _ in searchFocused = false }
    }

    private var sectionTitle: String {
        switch model.section {
        case .hosts: return "主机"
        case .files: return "文件"
        case .keys: return "SSH 密钥"
        case .snippets: return "代码片段"
        case .settings: return "设置"
        }
    }

    private var searchBox: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
            TextField("搜索主机…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Pal.text)
                .focused($searchFocused)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    /// 活动栏「文件」面板：有活动主机时显示其文件树，否则提示。
    @ViewBuilder
    private var filesPanel: some View {
        if let host = model.activeSessionHost, let tabId = model.activeSessionTabId {
            SidebarFileTree(state: model.fileTreeState(forTab: tabId, host: host), onOpenFile: { _ in })
                .id(tabId)
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
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.self) { group in
                Text(group)
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                ForEach(filteredHosts.filter { $0.group == group }) { host in
                    HostRow(host: host, model: model)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(8)
    }
}

struct HostRow: View {
    let host: Host
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        let active = model.activeHostId == host.id
        Button {
            model.openHost(host)
        } label: {
            HStack(spacing: 9) {
                Circle().fill(host.statusColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).font(.system(size: 13)).foregroundStyle(Pal.text)
                    Text(host.ipOrHost).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(
                active ? Pal.mauve.opacity(0.15) : (hover ? Pal.fill(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("打开终端") { model.openHostTerminal(host) }
            Button("打开文件") { model.openHostFiles(host) }
            Button("编辑主机") { model.beginEditHost(host) }
            Divider()
            Button("删除主机", role: .destructive) { model.deleteHost(host.id) }
        }
    }
}
