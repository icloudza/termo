import AppKit
import SwiftUI

/// RDP 鼠标输入捕获层：透明 NSView 覆盖在远端画面之上，把本地鼠标事件映射为远端桌面像素坐标后回调。
/// 渲染仍由上层 SwiftUI Image 负责；本层只管输入。坐标映射与 `scaledToFit` 的等比居中布局一致。
struct RDPMouseLayer: NSViewRepresentable {
    let remoteW: Int
    let remoteH: Int
    let onMove: (Int, Int) -> Void
    let onButton: (Int, Bool, Int, Int) -> Void
    let onWheel: (Int, Int, Int) -> Void

    func makeNSView(context: Context) -> RDPMouseView { RDPMouseView() }

    func updateNSView(_ v: RDPMouseView, context: Context) {
        v.remoteW = remoteW
        v.remoteH = remoteH
        v.onMove = onMove
        v.onButton = onButton
        v.onWheel = onWheel
    }
}

final class RDPMouseView: NSView {
    var remoteW = 0
    var remoteH = 0
    var onMove: ((Int, Int) -> Void)?
    var onButton: ((Int, Bool, Int, Int) -> Void)?
    var onWheel: ((Int, Int, Int) -> Void)?

    override var isFlipped: Bool { true }   // 顶左原点，匹配 RDP 坐标系与上层图像布局

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    /// 图像在本视图内的等比居中矩形（与 SwiftUI scaledToFit 一致）。
    private var imageRect: CGRect {
        guard remoteW > 0, remoteH > 0 else { return bounds }
        let iw = CGFloat(remoteW), ih = CGFloat(remoteH)
        let scale = min(bounds.width / iw, bounds.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func remotePoint(_ e: NSEvent) -> (Int, Int)? {
        guard remoteW > 0, remoteH > 0 else { return nil }
        let p = convert(e.locationInWindow, from: nil)   // isFlipped → 顶左
        let r = imageRect
        guard r.width > 0, r.height > 0 else { return nil }
        let fx = min(max((p.x - r.minX) / r.width, 0), 1)
        let fy = min(max((p.y - r.minY) / r.height, 0), 1)
        return (Int(fx * CGFloat(remoteW)), Int(fy * CGFloat(remoteH)))
    }

    private func move(_ e: NSEvent) { if let (x, y) = remotePoint(e) { onMove?(x, y) } }
    private func button(_ e: NSEvent, _ b: Int, _ down: Bool) { if let (x, y) = remotePoint(e) { onButton?(b, down, x, y) } }

    override func mouseMoved(with e: NSEvent) { move(e) }
    override func mouseDragged(with e: NSEvent) { move(e) }
    override func rightMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseDragged(with e: NSEvent) { move(e) }
    override func mouseDown(with e: NSEvent) { button(e, 0, true) }
    override func mouseUp(with e: NSEvent) { button(e, 0, false) }
    override func rightMouseDown(with e: NSEvent) { button(e, 1, true) }
    override func rightMouseUp(with e: NSEvent) { button(e, 1, false) }
    override func otherMouseDown(with e: NSEvent) { button(e, 2, true) }
    override func otherMouseUp(with e: NSEvent) { button(e, 2, false) }

    override func scrollWheel(with e: NSEvent) {
        guard let (x, y) = remotePoint(e) else { return }
        let dy = e.scrollingDeltaY
        if dy != 0 { onWheel?(Int((dy * 10).rounded()), x, y) }   // 放大到 RDP 滚轮量级
    }
}
