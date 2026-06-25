import SwiftUI

struct Workspace: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Pal.base
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if model.tabs.isEmpty {
            WelcomeView(model: model)
        } else {
            // tab 全量保活：所有打开的 tab 视图常驻 ZStack，仅用 opacity/hitTesting 切换可见性、不重建。
            // → 切 tab 瞬间无卡顿；终端、编辑器（含撤销历史/光标/滚动）随之常驻不销毁。
            // 焦点不再靠"重建触发 makeNSView 抢焦点"，改由 onChange→focusActiveTab 显式赋予当前 tab。
            ZStack {
                ForEach(model.tabs, id: \.id) { tab in
                    tabView(tab)
                        .opacity(tab.id == model.activeTabId ? 1 : 0)
                        .allowsHitTesting(tab.id == model.activeTabId)
                        .zIndex(tab.id == model.activeTabId ? 1 : 0)
                        .accessibilityHidden(tab.id != model.activeTabId)
                }
            }
            .onChange(of: model.activeTabId) { _ in model.focusActiveTab() }
            .onAppear { model.focusActiveTab() }
        }
    }

    @ViewBuilder
    private func tabView(_ tab: TabItem) -> some View {
        Group {
            switch tab.kind {
            case .terminal:
                TerminalSurface(terminal: model.terminalView(for: tab.id),
                                isActive: tab.id == model.activeTabId)
                    .padding(10)
            case .overview:
                if let host = model.host(tab.hostId) {
                    HostOverview(host: host, model: model)
                }
            case .files:
                if let host = model.host(tab.hostId) {
                    FileBrowser(state: model.browserState(for: tab.id, host: host),
                                onOpenFile: { model.openFile($0, host: host) })
                } else {
                    Text("无主机").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .editor:
                if let st = model.editorState(for: tab.id) {
                    FileViewerView(state: st, model: model, tabId: tab.id)
                } else {
                    Text("无法打开文件").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            case .rdp:
                if let host = model.host(tab.hostId) {
                    RDPSessionView(session: model.rdpSession(for: tab.id, host: host))
                } else {
                    Text("无主机").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            }
        }
        .id(tab.id)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "server.rack")
                .font(.system(size: 30))
                .foregroundStyle(Pal.mauve)
                .frame(width: 64, height: 64)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            VStack(spacing: 6) {
                Text("Termo").font(.system(size: 18, weight: .medium)).foregroundStyle(Pal.text)
                Text("从左侧选择一台主机，或打开一个本地终端开始。")
                    .font(.system(size: 13)).foregroundStyle(Pal.overlay)
            }
            Button {
                model.openLocalTerminal()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 13))
                    Text("打开本地终端").font(.system(size: 13))
                }
                .foregroundStyle(Pal.mauve)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9).stroke(Pal.mauve.opacity(0.25), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
