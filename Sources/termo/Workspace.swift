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
        if let id = model.activeTabId,
           let tab = model.tabs.first(where: { $0.id == id }) {
            switch tab.kind {
            case .terminal:
                TerminalSurface(terminal: model.terminalView(for: tab.id))
                    .id(tab.id)
                    .padding(10)
            case .overview:
                if let host = model.host(tab.hostId) {
                    HostOverview(host: host, model: model)
                }
            case .files:
                if let host = model.host(tab.hostId) {
                    FileBrowser(state: model.browserState(for: tab.id, host: host))
                        .id(tab.id)
                } else {
                    Text("无主机").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            }
        } else {
            WelcomeView(model: model)
        }
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
                Text("termo").font(.system(size: 18, weight: .medium)).foregroundStyle(Pal.text)
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
