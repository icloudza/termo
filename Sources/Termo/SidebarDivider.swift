import SwiftUI

struct SidebarDivider: View {
    @ObservedObject var layout: LayoutModel
    var maxWidth: CGFloat = 320          // 文件栏可传更大上限（深层目录树需要空间）
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragStartWidth: CGFloat = 0
    @State private var pendingWidth: CGFloat = 0   // 拖动中的目标宽度（松手才提交给 layout）

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
        // 拖动时只移动这条引导线 —— 面板与工作区保持冻结,松手才一次性改宽度。
        // 因此无论开多少标签 / 多大文件 / 多高吞吐终端,拖动过程恒为 O(1),绝对顺滑;
        // 真正的重排(终端 reflow、编辑器重布局)只在松手时发生一次。
        .overlay {
            if isDragging {
                Rectangle()
                    .fill(Pal.mauve.opacity(0.55))
                    .frame(width: 2)
                    .offset(x: pendingWidth - dragStartWidth)
                    .allowsHitTesting(false)
            }
        }
        // 用 onContinuousHover 在每次移动时重设光标：push/pop 会被 SwiftUI 的 tracking area
        // 在鼠标移动时重置回箭头，逐帧 set 才能稳定压住，显示左右拉伸光标。
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isHovering { isHovering = true }
                NSCursor.resizeLeftRight.set()
            case .ended:
                if isHovering { isHovering = false }
                NSCursor.arrow.set()
            }
        }
        .onTapGesture(count: 2) {
            // 瞬间开合(不加动画):滑动动画会逐帧重排工作区 → 卡顿。
            layout.sidebarWidth = layout.sidebarWidth < 10 ? 224 : 0
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartWidth = layout.sidebarWidth
                        pendingWidth = dragStartWidth
                    }
                    // 仅更新本地目标宽度,不写 layout —— 拖动中不触发任何重排。
                    pendingWidth = min(max(dragStartWidth + value.translation.width, 0), maxWidth)
                    // 拖动中持续断言拉伸光标，防止鼠标移出窄热区时被重置回箭头。
                    NSCursor.resizeLeftRight.set()
                }
                .onEnded { _ in
                    isDragging = false
                    var w = pendingWidth
                    if w < collapseThreshold { w = 0 }
                    else if w < 140 { w = 140 }
                    // 松手:带轻动画滑到目标位置(从冻结的起始宽度补间到 w),避免面板"硬跳"。
                    // 代价:动画期间宽度逐帧变化 → 终端会逐帧 reflow;非终端标签则顺滑。
                    // 若觉得这段滑动仍顿,把本行换回 `layout.sidebarWidth = w`(瞬间到位)即可。
                    withAnimation(.easeOut(duration: 0.12)) { layout.sidebarWidth = w }
                }
        )
    }
}
