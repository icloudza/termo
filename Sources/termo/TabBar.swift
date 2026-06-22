import SwiftUI

struct TabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            TabStrip(
                newKey: model.tabs.count,
                activeKey: model.activeTabId ?? 0,
                activeIndex: model.tabs.firstIndex(where: { $0.id == model.activeTabId }) ?? 0,
                tabCount: model.tabs.count
            ) {
                HStack(spacing: 4) {
                    ForEach(model.tabs) { tab in
                        TabChip(tab: tab, model: model)
                    }
                }
            }
            Button {
                model.openLocalTerminal()
            } label: {
                Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 34)
                    .offset(y: -5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(maxWidth: .infinity)
        .background(Pal.mantle)
    }
}

struct TabChip: View {
    let tab: TabItem
    @ObservedObject var model: AppModel
    @State private var hover = false

    private var symbol: String {
        switch tab.kind {
        case .overview: return "square.grid.2x2"
        case .terminal: return "terminal"
        case .files: return "folder"
        }
    }

    var body: some View {
        let active = model.activeTabId == tab.id
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11))
                .foregroundStyle(active ? Pal.text : Pal.overlay)
            Text(tab.title).font(.system(size: 12))
                .foregroundStyle(active ? Pal.text : Pal.subtext)
                .lineLimit(1)
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 16, height: 16)
                    .background(
                        hover ? Color.white.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4)
                    )
            }
            .buttonStyle(.plain)
            .opacity(active || hover ? 1 : 0)
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
        .background(
            active ? Color.white.opacity(0.08) : (hover ? Color.white.opacity(0.04) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { hover = $0 }
        .accessibilityIdentifier(String(tab.id))
    }
}
