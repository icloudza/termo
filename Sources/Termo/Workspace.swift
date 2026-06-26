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
            // 渲染策略（混合）：
            // - **编辑器 tab 常驻**（opacity 切显隐、不 detach）。原因：编辑器是 NSHostingView→SourceEditor
            //   两层嵌套,一旦从窗口 detach 再 attach，SwiftUI 会重建内部控制器 → 丢撤销栈 + 重排版 churn。
            //   只切显隐就不会 detach，控制器/撤销/光标/滚动全程存活。代价：缩放时各编辑器重布局，但不换行=轻、
            //   缩略图缩放期已跳过，开销小；且编辑器不像终端要 reflow 整缓冲。
            // - **其它 tab（终端/文件/概览/RDP）只渲染活动的**。终端视图是模型持有的裸 NSView，detach/attach 不重建、
            //   PTY 后台不断；其它要么无状态、要么模型持有。这把"标签越多越卡"的大头（终端 reflow×N）压到 O(1)。
            ZStack {
                ForEach(model.tabs.filter { $0.kind == .editor }, id: \.id) { tab in
                    tabView(tab)
                        .opacity(tab.id == model.activeTabId ? 1 : 0)
                        .allowsHitTesting(tab.id == model.activeTabId)
                        .zIndex(tab.id == model.activeTabId ? 1 : 0)
                        .accessibilityHidden(tab.id != model.activeTabId)
                }
                if let active = model.tabs.first(where: { $0.id == model.activeTabId }), active.kind != .editor {
                    tabView(active).zIndex(2)
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
