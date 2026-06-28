// 生成 DMG 安装窗口的品牌叠层（@1x + @2x），离屏 CoreGraphics/CoreText 渲染，无需显示器。
// 透明底：只画品牌字标 + 拖拽箭头 + 指引，浮在默认浅色 Finder 窗口上（不铺任何底色）。
// >_ 复用托盘 logo 的描边路径（圆角端点、蓝色 _），与菜单栏图标视觉一致。
// 坐标系与 create-dmg 对齐：create-dmg 窗口 660x400（含标题栏），背景图高度取「可视内容高度」
// 660x368（≈400-标题栏28），使图正好铺满内容区、底部不被标题栏挤出而切到指引文字；
// App 图标(170,198)、Applications(490,198)、图标 128，对应背景里箭头/图标行 image-y = 368-198 = 170。
// 用法：swift make-dmg-background.swift <输出目录>  → 产出 background.png / background@2x.png
import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// 取系统圆体（SF Pro Rounded）：用 NSFont 的 .rounded 设计变体最可靠（按 PostScript 名常取不到）。
/// NSFont 与 CTFont 免费桥接，可直接交给 CoreText 绘制。
func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let d = base.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: size) ?? base }
    return base
}

let W: CGFloat = 660, H: CGFloat = 368
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
// 浅色窗口配色：深色墨水文字 + 品牌蓝 _（取自托盘 logo barBlue）
let ink = c(60, 63, 76)          // 字标 / 指引
let blue = c(51, 133, 255)       // _ 与箭头头部（品牌蓝）
let gray = c(140, 143, 160)      // 副标题 / 箭头杆
let subtle = c(120, 124, 143)

func attr(_ s: String, _ font: CTFont, _ color: CGColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: color,
    ])
}
func measure(_ line: CTLine) -> CGFloat {
    var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
    return CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
}
func drawCentered(_ s: NSAttributedString, centerX: CGFloat, baselineY: CGFloat, in ctx: CGContext) {
    let line = CTLineCreateWithAttributedString(s as CFAttributedString)
    ctx.textPosition = CGPoint(x: centerX - measure(line)/2, y: baselineY)
    CTLineDraw(line, ctx)
}

// 托盘 logo 的 >_ 路径（18 单位设计，bottom-left；设计 y=4.4 为基线，放大 s 倍，原点 ox/by）。
func drawPrompt(ox: CGFloat, baselineY: CGFloat, s: CGFloat, in ctx: CGContext) {
    func P(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: ox + dx*s, y: baselineY + (dy-4.4)*s) }
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(ink); ctx.setLineWidth(2.3*s)              // chevron ">"
    ctx.beginPath(); ctx.move(to: P(4.3,13.6)); ctx.addLine(to: P(9.4,9)); ctx.addLine(to: P(4.3,4.4)); ctx.strokePath()
    ctx.setStrokeColor(blue); ctx.setLineWidth(2.3*s)            // 下划线 "_"
    ctx.beginPath(); ctx.move(to: P(12.3,4.4)); ctx.addLine(to: P(16.0,4.4)); ctx.strokePath()
}
let promptGlyphWidth: CGFloat = (16.0 - 4.3)  // 设计单位宽度

func render(scale: CGFloat) -> CGImage? {
    let pw = Int(W*scale), ph = Int(H*scale)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    // 透明底：不铺任何底色（context 初始即全透明）。

    // 品牌字标：>_（圆角描边）+ Termo（圆体）。整体水平居中。
    let s: CGFloat = 3.2
    let gW = promptGlyphWidth * s
    let gap: CGFloat = 16
    let termoFont = roundedFont(40, .semibold)
    let termoLine = CTLineCreateWithAttributedString(attr("Termo", termoFont, ink) as CFAttributedString)
    let tW = measure(termoLine)
    let total = gW + gap + tW
    let startX = (W - total) / 2
    let baseY: CGFloat = H - 60
    drawPrompt(ox: startX - 4.3*s, baselineY: baseY, s: s, in: ctx)
    ctx.textPosition = CGPoint(x: startX + gW + gap, y: baseY)
    CTLineDraw(termoLine, ctx)

    // 副标题
    let subFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 14, nil)
    drawCentered(attr("服务器 · 主机管理工具", subFont, subtle), centerX: W/2, baselineY: H-88, in: ctx)

    // 拖拽箭头（两图标之间，图标中心 image-y = H-198 = 170）
    let ay: CGFloat = 170, ax0: CGFloat = 268, ax1: CGFloat = 392
    ctx.setStrokeColor(gray); ctx.setLineWidth(3); ctx.setLineCap(.round)
    ctx.beginPath(); ctx.move(to: CGPoint(x: ax0, y: ay)); ctx.addLine(to: CGPoint(x: ax1, y: ay)); ctx.strokePath()
    ctx.setFillColor(blue)
    ctx.beginPath(); ctx.move(to: CGPoint(x: ax1+12, y: ay))
    ctx.addLine(to: CGPoint(x: ax1-6, y: ay+8)); ctx.addLine(to: CGPoint(x: ax1-6, y: ay-8))
    ctx.closePath(); ctx.fillPath()

    // 底部指引
    let hintFont = CTFontCreateWithName("PingFangSC-Medium" as CFString, 15, nil)
    drawCentered(attr("将 Termo 拖到「应用程序」完成安装", hintFont, ink), centerX: W/2, baselineY: 40, in: ctx)

    return ctx.makeImage()
}

func write(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("✓ \(path)")
}

if let a = render(scale: 1) { write(a, to: "\(outDir)/background.png") }
if let b = render(scale: 2) { write(b, to: "\(outDir)/background@2x.png") }
