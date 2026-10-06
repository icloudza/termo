import AppKit
import SwiftUI

/// 全局自定义 Tooltip：用一个**无边框浮动面板**承载 SwiftUI 卡片，悬停延迟后在光标附近弹出。
/// 走独立 window → 不被 ScrollView/父视图裁剪；样式完全自定义（对齐 App 风格，见 [[ui-component-style]]）。
/// 用法：任意 View 加 `.tooltip("完整文本")` 或 `.tooltip(text, when: 是否截断)`。
@MainActor
final class TooltipController {
    static let shared = TooltipController()
    private var panel: NSPanel?
    private var hosting: NSHostingView<TooltipView>?
    private var showWork: DispatchWorkItem?
    private var owner = 0            // 当前（待）显示的 tooltip 归属哪次悬停
    private var lastHidden = Date.distantPast
    private var monitor: Any?

    /// 悬停进入：延迟后在当前光标处弹出。返回令牌，离开/消失时凭它收起——
    /// 从 A 移到 B 时 A 的「离开」晚到，不能把 B 刚排上的弹出取消掉。
    @discardableResult
    func scheduleShow(_ text: String, delay: TimeInterval = 0.45) -> Int {
        installMonitorIfNeeded()
        // 刚看过一个提示、紧接着移到相邻按钮：立即显示（同系统工具提示），不用每个都再等一遍。
        let warm = panel?.isVisible == true || Date().timeIntervalSince(lastHidden) < 0.6
        showWork?.cancel()
        panel?.orderOut(nil)
        owner &+= 1
        guard !text.isEmpty else { return owner }
        let work = DispatchWorkItem { [weak self] in self?.present(text) }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (warm ? 0.05 : delay), execute: work)
        return owner
    }

    func hide(_ token: Int) {
        guard token == owner else { return }
        showWork?.cancel()
        if panel?.isVisible == true { lastHidden = Date() }
        panel?.orderOut(nil)
    }

    /// 点击、按键、滚动时立即收起并取消待弹出的提示：否则点开弹窗后，提示会在 0.45s 后浮到新弹窗上面。
    private func hideAll() {
        guard showWork != nil || panel?.isVisible == true else { return }   // 滚动/打字时每个事件都会来，空闲时直接返回
        showWork?.cancel()
        showWork = nil
        owner &+= 1
        lastHidden = .distantPast
        panel?.orderOut(nil)
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { event in
            MainActor.assumeIsolated { TooltipController.shared.hideAll() }
            return event
        }
    }

    // 文本最大宽度（超出则换行）。
    private static let maxTextWidth: CGFloat = 440

    /// 先用 NSString 量出单行宽度，据此决定一个确定的换行宽度交给 SwiftUI。
    /// 高度仍由 SwiftUI 自己在该宽度下排版得出（fittingSize），避免 fixedSize+maxWidth 测高与渲染不一致导致裁切。
    private static func wrapWidth(for text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11.5)
        let single = (text as NSString).size(withAttributes: [.font: font]).width
        return min(ceil(single) + 2, maxTextWidth)   // +2 余量，避免临界值被迫换行
    }

    private func present(_ text: String) {
        let panel = ensurePanel()
        hosting?.rootView = TooltipView(text: text, textWidth: Self.wrapWidth(for: text))
        panel.layoutIfNeeded()
        let size = hosting?.fittingSize ?? CGSize(width: 120, height: 28)

        // 光标右下方弹出（screen 坐标，原点左下）；夹到当前屏幕可视区内。
        let loc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(loc) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = loc.x + 14
        var y = loc.y - size.height - 10
        if x + size.width > vis.maxX { x = loc.x - size.width - 14 }      // 右侧放不下→翻到左侧
        x = min(max(x, vis.minX + 4), vis.maxX - size.width - 4)
        if y < vis.minY { y = loc.y + 18 }                                // 下方放不下→翻到上方
        y = min(max(y, vis.minY + 4), vis.maxY - size.height - 4)

        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        panel.orderFront(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 28),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .popUpMenu                 // 浮在其它窗口/弹窗之上
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false                  // 阴影由 SwiftUI 卡片画
        p.ignoresMouseEvents = true          // 永不抢事件/焦点
        p.hidesOnDeactivate = true           // 切到别的 App 时不残留在别人的窗口上
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let h = NSHostingView(rootView: TooltipView(text: "", textWidth: 0))
        p.contentView = h
        hosting = h
        panel = p
        return p
    }
}

/// Tooltip 卡片视图（自定义样式）。
private struct TooltipView: View {
    let text: String
    let textWidth: CGFloat   // 由 controller 量定的确定换行宽度
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Pal.text)
            .multilineTextAlignment(.leading)
            .lineLimit(3)
            // 宽度确定后再 fixedSize 垂直方向：高度按该宽度真实换行排版得出，杜绝多行被裁。
            .frame(width: textWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.fill(0.10), lineWidth: 1))
            .padding(2)                      // 无阴影，仅留极小余量防描边贴边被裁
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

extension View {
    /// 全局自定义 Tooltip：悬停延迟后在光标处弹出。`when` 为 false 时不挂（如未截断的文本）。
    func tooltip(_ text: String, when condition: Bool = true) -> some View {
        modifier(TooltipModifier(text: condition ? text : ""))
    }
}

private struct TooltipModifier: ViewModifier {
    let text: String
    @State private var token: Int?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && !text.isEmpty {
                    token = TooltipController.shared.scheduleShow(text)
                } else if let token {
                    TooltipController.shared.hide(token)
                }
            }
            // 延迟期间源视图消失（弹窗关闭、隐藏到菜单栏）收不到「离开」，不收起就会一直留在屏幕上。
            .onDisappear { if let token { TooltipController.shared.hide(token) } }
    }
}
