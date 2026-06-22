import AppKit
import SwiftUI

struct ActivityBar: View {
    @ObservedObject var model: AppModel
    @State private var isFullScreen = false

    private let items: [(String, Section)] = [
        ("server.rack", .hosts),
        ("folder", .files),
        ("key", .keys),
        ("chevron.left.forwardslash.chevron.right", .snippets),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(items, id: \.1) { symbol, section in
                item(symbol, section)
            }
            Spacer()
            item("gearshape", .settings)
        }
        .padding(.top, isFullScreen ? 12 : 52)
        .padding(.bottom, 12)
        .frame(width: 68)
        .frame(maxHeight: .infinity)
        .background(Pal.crust)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    @ViewBuilder
    private func item(_ symbol: String, _ section: Section) -> some View {
        let selected = model.section == section
        Button {
            model.section = section
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(selected ? Pal.mauve : Pal.overlay)
                .frame(width: 38, height: 38)
                .background(
                    selected ? Pal.mauve.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
