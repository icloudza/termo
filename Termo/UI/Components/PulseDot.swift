import AppKit
import SwiftUI

/// 常驻的呼吸/扩散圆点。用 CALayer + CABasicAnimation 实现：动画由渲染服务器驱动，App 主线程零开销。
/// SwiftUI 的 repeatForever 会在主线程逐帧求值并提交整窗事务，挂在转发这类一跑几小时的状态上会持续耗 CPU。
struct PulseDot: NSViewRepresentable {
    enum Style {
        case breathe   // 原地缩放 + 明暗往返
        case ripple    // 向外扩散并渐隐
    }

    let color: Color
    let diameter: CGFloat
    var style: Style = .breathe

    func makeNSView(context: Context) -> PulseDotView { PulseDotView(style: style) }

    func updateNSView(_ nsView: PulseDotView, context: Context) {
        nsView.update(color: NSColor(color), diameter: diameter)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseDotView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

final class PulseDotView: NSView {
    private let style: PulseDot.Style
    private let dot = CALayer()
    private var color: NSColor?
    private var diameter: CGFloat = 0

    init(style: PulseDot.Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(dot)
        clipsToBounds = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(color: NSColor, diameter: CGFloat) {
        if color != self.color {
            self.color = color
            dot.backgroundColor = color.cgColor
        }
        if diameter != self.diameter {
            self.diameter = diameter
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
        dot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dot.removeAllAnimations()
        if window != nil { startAnimation() }
    }

    private func startAnimation() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        let fade = CABasicAnimation(keyPath: "opacity")
        let group = CAAnimationGroup()
        switch style {
        case .breathe:
            scale.fromValue = 0.85; scale.toValue = 1.0
            fade.fromValue = 0.6; fade.toValue = 1.0
            group.duration = 1.1
            group.autoreverses = true
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        case .ripple:
            scale.fromValue = 1.0; scale.toValue = 2.2
            fade.fromValue = 0.6; fade.toValue = 0.0
            group.duration = 1.4
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        group.animations = [scale, fade]
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        dot.add(group, forKey: "pulse")
    }
}
