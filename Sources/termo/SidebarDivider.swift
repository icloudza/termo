import SwiftUI

struct SidebarDivider: View {
    @Binding var width: CGFloat
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0

    private let maxWidth: CGFloat = 320
    private let collapseThreshold: CGFloat = 60
    private var active: Bool { isHovering || isDragging }

    var body: some View {
        ZStack {
            Pal.mantle

            if active {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Pal.fill(0.08))
                    .frame(width: 5, height: 48)
            }
        }
        .frame(width: 5)
        .contentShape(Rectangle())
        .onHover { hover in
            isHovering = hover
            if hover { NSCursor.resizeLeftRight.push() }
            else { NSCursor.pop() }
        }
        .onTapGesture(count: 2) {
            withAnimation(.easeOut(duration: 0.2)) {
                width = width < 10 ? 224 : 0
            }
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartWidth = width
                    }
                    width = min(max(dragStartWidth + value.translation.width, 0), maxWidth)
                }
                .onEnded { _ in
                    isDragging = false
                    if width < collapseThreshold {
                        withAnimation(.easeOut(duration: 0.15)) { width = 0 }
                    } else if width < 140 {
                        withAnimation(.easeOut(duration: 0.15)) { width = 140 }
                    }
                }
        )
    }
}
