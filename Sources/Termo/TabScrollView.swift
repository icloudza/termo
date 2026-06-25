import AppKit
import SwiftUI

final class ScrollMetrics: ObservableObject {
    @Published var offsetX: CGFloat = 0
    @Published var contentW: CGFloat = 0
    @Published var visibleW: CGFloat = 0
    var maxScroll: CGFloat { max(0, contentW - visibleW) }
    var scrollTo: ((CGFloat) -> Void)?

    /// 仅在有实际变化时才赋值发布。`@Published` 即便赋相同值也会触发 objectWillChange，
    /// 而 `updateNSView` 每次更新都回写这些值 → 会形成「回写→重渲染→又回写」的自激环（CPU 跑满）。
    /// 用阈值比较（亚像素抖动忽略）+ 改了才发布，彻底打破该环。
    func set(offsetX: CGFloat, contentW: CGFloat, visibleW: CGFloat) {
        if abs(self.offsetX - offsetX) > 0.5 { self.offsetX = offsetX }
        if abs(self.contentW - contentW) > 0.5 { self.contentW = contentW }
        if abs(self.visibleW - visibleW) > 0.5 { self.visibleW = visibleW }
    }
}

final class HScroll: NSScrollView {
    var onScroll: (() -> Void)?

    override func scrollWheel(with e: NSEvent) {
        guard let doc = documentView else { super.scrollWheel(with: e); return }
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        var d = e.scrollingDeltaX
        if abs(e.scrollingDeltaY) > abs(d) { d = e.scrollingDeltaY }
        if d == 0 { d = e.deltaX != 0 ? e.deltaX : e.deltaY }
        let speed: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
        var x = contentView.bounds.origin.x - d * speed
        x = min(max(0, x), maxX)
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }

    override func layout() {
        super.layout()
        if let doc = documentView {
            let w = max(doc.fittingSize.width, 1)
            let h = contentView.bounds.height
            let target = NSRect(x: 0, y: 0, width: w, height: h)
            if !doc.frame.equalTo(target) { doc.frame = target }
        }
        onScroll?()
    }
}

/// 忽略窗口安全区的 NSHostingView：标签内容不被标题栏 inset 推下去。
final class SafeHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets {
        .init(top: 0, left: 0, bottom: 0, right: 0)
    }
}

struct HScrollRep<Content: View>: NSViewRepresentable {
    @ObservedObject var metrics: ScrollMetrics
    var newKey: Int
    var activeKey: Int
    var activeIndex: Int
    var tabCount: Int
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> HScroll {
        let sv = HScroll()
        sv.hasHorizontalScroller = false
        sv.hasVerticalScroller = false
        sv.drawsBackground = false
        sv.backgroundColor = .clear
        sv.contentView.drawsBackground = false
        sv.verticalScrollElasticity = .none
        sv.horizontalScrollElasticity = .allowed
        sv.automaticallyAdjustsContentInsets = false
        sv.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)

        let hosting = SafeHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        sv.documentView = hosting
        context.coordinator.hosting = hosting

        let push: () -> Void = { [weak sv] in
            guard let sv else { return }
            let ox = sv.contentView.bounds.origin.x
            let cw = sv.documentView?.frame.width ?? 0
            let vw = sv.contentView.bounds.width
            DispatchQueue.main.async {
                metrics.set(offsetX: ox, contentW: cw, visibleW: vw)
            }
        }
        sv.onScroll = push
        sv.contentView.postsBoundsChangedNotifications = true
        context.coordinator.obs = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main
        ) { _ in push() }

        metrics.scrollTo = { [weak sv] x in
            guard let sv else { return }
            sv.contentView.scroll(to: NSPoint(x: x, y: 0))
            sv.reflectScrolledClipView(sv.contentView)
        }
        return sv
    }

    func updateNSView(_ sv: HScroll, context: Context) {
        context.coordinator.hosting?.rootView = content
        sv.needsLayout = true
        DispatchQueue.main.async {
            sv.layoutSubtreeIfNeeded()
            let co = context.coordinator
            guard let doc = sv.documentView else { return }
            let clipW = sv.contentView.bounds.width
            let docW = doc.frame.width
            let maxScrollX = max(0, docW - clipW)
            let curX = sv.contentView.bounds.origin.x

            let isNew = newKey > co.lastKey
            co.lastKey = newKey

            // 新建标签：平滑滚到最右
            if isNew {
                co.lastActiveKey = activeKey
                smoothScroll(sv, to: maxScrollX)
            }
            // 切换标签（非新建时）：如果点的标签在边缘，平滑滚动露出它后面/前面的邻居
            else if activeKey != co.lastActiveKey, docW > clipW {
                co.lastActiveKey = activeKey
                let tc = max(1, tabCount)
                let tabW = docW / CGFloat(tc)
                let tabLeft = CGFloat(activeIndex) * tabW
                let tabRight = tabLeft + tabW

                var targetX = curX
                if tabRight > curX + clipW - tabW * 0.5 {
                    // 点了右边缘的标签，滚到露出它后面一个
                    targetX = min(maxScrollX, tabRight - clipW + tabW)
                } else if tabLeft < curX + tabW * 0.5 {
                    // 点了左边缘的标签，滚到露出它前面一个
                    targetX = max(0, tabLeft - tabW)
                }
                if abs(targetX - curX) > 1 {
                    smoothScroll(sv, to: targetX)
                }
            } else {
                co.lastActiveKey = activeKey
            }

            metrics.set(offsetX: sv.contentView.bounds.origin.x, contentW: docW, visibleW: clipW)
        }
    }

    private func smoothScroll(_ sv: HScroll, to x: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = .init(name: .easeInEaseOut)
            sv.contentView.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
        }
        sv.reflectScrolledClipView(sv.contentView)
    }

    static func dismantleNSView(_ nsView: HScroll, coordinator: Coordinator) {
        if let o = coordinator.obs { NotificationCenter.default.removeObserver(o) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var hosting: SafeHostingView<Content>?
        var obs: NSObjectProtocol?
        var lastKey = 0
        var lastActiveKey = 0
    }
}

struct TabStrip<Content: View>: View {
    var newKey: Int
    var activeKey: Int
    var activeIndex: Int
    var tabCount: Int
    @ViewBuilder var content: Content
    @StateObject private var metrics = ScrollMetrics()
    @State private var hovering = false
    @State private var dragStart: CGFloat?

    init(newKey: Int, activeKey: Int, activeIndex: Int = 0, tabCount: Int = 0, @ViewBuilder content: () -> Content) {
        self.newKey = newKey
        self.activeKey = activeKey
        self.activeIndex = activeIndex
        self.tabCount = tabCount
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 3) {
            HScrollRep(metrics: metrics, newKey: newKey, activeKey: activeKey, activeIndex: activeIndex, tabCount: tabCount) { content }
                .frame(height: 34)
            scrollbar
                .frame(height: 5)
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var scrollbar: some View {
        GeometryReader { g in
            if metrics.contentW > metrics.visibleW + 1, g.size.width > 0 {
                let track = g.size.width
                let thumbW = max(28, track * track / metrics.contentW)
                let maxX = max(0, track - thumbW)
                let x = metrics.maxScroll > 0 ? metrics.offsetX / metrics.maxScroll * maxX : 0
                Capsule()
                    .fill(Pal.fill(hovering ? 0.32 : 0.18))
                    .frame(width: thumbW, height: 4)
                    .frame(width: thumbW, height: g.size.height)
                    .contentShape(Rectangle())
                    .position(x: x + thumbW / 2, y: g.size.height / 2)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if dragStart == nil { dragStart = metrics.offsetX }
                                if maxX > 0, let start = dragStart {
                                    let off = min(max(0, start + v.translation.width / maxX * metrics.maxScroll), metrics.maxScroll)
                                    metrics.scrollTo?(off)
                                }
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
        }
    }
}
