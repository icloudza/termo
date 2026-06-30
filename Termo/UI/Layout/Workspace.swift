import SwiftUI

struct Workspace: View {
    // model 用纯 let 持有（只调方法、不订阅）：AppModel 的无关 @Published 变化不再触发 Workspace 重算。
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared
    // 非活动编辑器的冻结尺寸：仅首次布局时定一次。缩放时只有活动编辑器随实时尺寸重排，隐藏编辑器尺寸不变、不触发 TextKit 重排。
    @State private var frozenEditorSize: CGSize = .zero

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
        if tabs.tabs.isEmpty {
            WelcomeView(model: model)
        } else {
            // 渲染策略（混合）：
            // - **编辑器 tab 常驻**（opacity 切显隐、不 detach）。原因：编辑器是 NSHostingView→SourceEditor
            //   两层嵌套,一旦从窗口 detach 再 attach，SwiftUI 会重建内部控制器 → 丢撤销栈 + 重排版 churn。
            //   只切显隐就不会 detach，控制器/撤销/光标/滚动全程存活。代价：缩放时各编辑器重布局，但不换行=轻、
            //   缩略图缩放期已跳过，开销小；且编辑器不像终端要 reflow 整缓冲。
            // - **其它 tab（终端/文件/概览/RDP）只渲染活动的**。终端视图是模型持有的裸 NSView，detach/attach 不重建、
            //   PTY 后台不断；其它要么无状态、要么模型持有。这把"标签越多越卡"的大头（终端 reflow×N）压到 O(1)。
            // GeometryReader 取实时尺寸：活动编辑器随之填满并重排（仅 1 个，开销等同只开一个标签）；
            // 隐藏编辑器钉死在 frozenEditorSize，缩放/拖侧栏时容器尺寸不变 → 不重排。切到它时才取实时尺寸重排一次。
            GeometryReader { geo in
                // topLeading 对齐：活动编辑器钉在左上 (0,0) 填满；隐藏编辑器即便冻结在更大尺寸也只向右下溢出，
                // 不会把活动编辑器居中挤偏（窗口缩到比 frozenEditorSize 小时尤为关键）。
                ZStack(alignment: .topLeading) {
                    ForEach(tabs.tabs.filter { $0.kind == .editor }, id: \.id) { tab in
                        let isActive = tab.id == tabs.activeTabId
                        tabView(tab)
                            .frame(width: isActive ? geo.size.width : max(1, frozenEditorSize.width),
                                   height: isActive ? geo.size.height : max(1, frozenEditorSize.height))
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                            .zIndex(isActive ? 1 : 0)
                            .accessibilityHidden(!isActive)
                    }
                    if let active = tabs.tabs.first(where: { $0.id == tabs.activeTabId }), active.kind != .editor {
                        tabView(active)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .zIndex(2)
                    }
                }
                // 钉死为当前 geo 尺寸：窗口缩到比 frozenEditorSize 小时，ZStack 不会被那个更大的隐藏编辑器撑大、
                // 进而把活动编辑器居中错位；超出部分裁掉（隐藏编辑器本就不可见）。
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
                .onAppear { if frozenEditorSize == .zero { frozenEditorSize = geo.size } }
                .onChange(of: geo.size) { s in if frozenEditorSize == .zero { frozenEditorSize = s } }
            }
            .onChange(of: tabs.activeTabId) { _ in model.focusActiveTab() }
            .onAppear { model.focusActiveTab() }
        }
    }

    @ViewBuilder
    private func tabView(_ tab: TabItem) -> some View {
        Group {
            switch tab.kind {
            case .terminal:
                TerminalDropArea(terminal: model.terminalView(for: tab.id),
                                 isActive: tab.id == tabs.activeTabId,
                                 model: model, tabId: tab.id,
                                 canUpload: model.host(tab.hostId)?.ssh != nil)
                    .overlay {
                        if let conn = model.terminalConn(for: tab.id) {
                            TerminalReconnectOverlay(conn: conn) { model.manualReconnectTerminal(tab.id) }
                        }
                    }
                    .padding(10)
            case .overview:
                if let host = model.host(tab.hostId) {
                    HostOverview(host: host, model: model)
                }
            case .files:
                if let host = model.host(tab.hostId) {
                    FileBrowser(state: model.browserState(for: tab.id, host: host),
                                host: host, model: model,
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
                Text(AppEnv.localTerminalEnabled ? "从左侧选择一台主机，或打开一个本地终端开始。" : "从左侧选择一台主机开始。")
                    .font(.system(size: 13)).foregroundStyle(Pal.overlay)
            }
            if AppEnv.localTerminalEnabled {   // MAS 沙盒下隐藏本地终端入口
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
                .pointerCursor()
            }
        }
    }
}
