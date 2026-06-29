import AppKit
import CoreText
import SwiftUI

/// 发行版 Logo —— 用随 App 打包的 **Font Logos**(OFL 许可)字体渲染,运行时注册到本进程,
/// 因此任何机器(含分发给用户的)都能显示,无需系统装字体。
/// 数据源:主机探测得到的 `specs.os`(如 "Ubuntu 22.04.3 LTS");未探测/未识别时,
/// 调用方([[HostLeadingIcon]])回退为延迟色圆点。
enum OSLogo {
    /// 注册打包字体并返回其 PostScript 名(供 `.custom` 渲染);资源缺失/注册失败 → nil → 回退圆点。
    /// `static let` 保证只注册一次(在 [[TermoApp]] 启动时预热,首帧即可用)。
    static let fontName: String? = {
        guard let url = Bundle.app.url(forResource: "font-logos", withExtension: "ttf"),
              let provider = CGDataProvider(url: url as CFURL),
              let cgFont = CGFont(provider) else { return nil }
        CTFontManagerRegisterGraphicsFont(cgFont, nil)   // .process 作用域:仅本进程可见
        return (cgFont.postScriptName as String?) ?? "Font Logos"
    }()

    /// os 描述串 → (Font Logos 字形, 品牌色)。识别不出返回 nil。
    /// 码点 = U+F300 + font-logos 的 offset(见仓库 icons.tsv)。
    static func info(for os: String) -> (glyph: String, color: Color)? {
        let s = os.lowercased()
        if s.contains("ubuntu")   { return ("\u{F31B}", Color(hex: 0xE95420)) }
        if s.contains("debian")   { return ("\u{F306}", Color(hex: 0xA80030)) }
        if s.contains("centos")   { return ("\u{F304}", Color(hex: 0x9CCD2A)) }
        if s.contains("fedora")   { return ("\u{F30A}", Color(hex: 0x3C6EB4)) }
        if s.contains("rocky")    { return ("\u{F32B}", Color(hex: 0x10B981)) }
        if s.contains("alma")     { return ("\u{F31D}", Color(hex: 0x0D7DBC)) }
        if s.contains("red hat") || s.contains("redhat") || s.contains("rhel") {
            return ("\u{F316}", Color(hex: 0xEE0000))
        }
        if s.contains("kali")     { return ("\u{F327}", Color(hex: 0x367BF0)) }
        if s.contains("manjaro")  { return ("\u{F312}", Color(hex: 0x35BF5C)) }
        if s.contains("arch")     { return ("\u{F303}", Color(hex: 0x1793D1)) }
        if s.contains("alpine")   { return ("\u{F300}", Color(hex: 0x0D597F)) }
        if s.contains("suse") || s.contains("sles") { return ("\u{F314}", Color(hex: 0x30BA78)) }
        if s.contains("mint")     { return ("\u{F30E}", Color(hex: 0x87CF3E)) }
        if s.contains("gentoo")   { return ("\u{F30D}", Color(hex: 0x54487A)) }
        if s.contains("nixos")    { return ("\u{F313}", Color(hex: 0x5277C3)) }
        if s.contains("void")     { return ("\u{F32E}", Color(hex: 0x478061)) }
        if s.contains("raspbian") || s.contains("raspberry") { return ("\u{F315}", Color(hex: 0xC51A4A)) }
        if s.contains("darwin") || s.contains("macos") || s.contains("mac os") {
            return ("\u{F302}", Color(hex: 0xA2AAAD))   // Apple
        }
        // 已知是 Linux 但发行版不明 → 通用 Tux(F31A)。
        // 注:Windows 在开源 logo 字体里没有(商标),RDP/Windows 主机会回退到圆点。
        if s.contains("linux") || s.contains("gnu") { return ("\u{F31A}", Color(hex: 0x9CA3AF)) }
        return nil
    }
}

/// 主机行左侧图标:实心圆角方块,底色取 OS 品牌色、logo 描白(无 logo 的 Windows/未识别走纯色兜底);
/// 右下角叠加延迟等级小点。固定 28pt 槽位 → 列表里名字左缘始终对齐。
struct HostLeadingIcon: View {
    let host: Host
    @ObservedObject private var theme = ThemeManager.shared

    private static let side: CGFloat = 28
    private static let radius: CGFloat = 7

    var body: some View {
        // SSH 主机用探测到的发行版(specs.os),回退到存储的 os 字段;RDP 视为 Windows。
        let osStr = host.isRDP ? "windows" : (host.specs?.os ?? host.os)
        let dotColor = LatencyLevel(ms: host.latencyMs).color   // 延迟等级着色:快绿、慢黄/红,未探测/不可达为灰
        ZStack(alignment: .bottomTrailing) {
            iconTile(osStr)
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(Pal.mantle, lineWidth: 2))   // 描边与侧栏底色融合，使小点从实心底里分离
                .offset(x: 1, y: 1)
        }
        .frame(width: Self.side, height: Self.side)
    }

    @ViewBuilder
    private func iconTile(_ osStr: String) -> some View {
        if let name = OSLogo.fontName, let logo = OSLogo.info(for: osStr) {
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(logo.color)
                .overlay(Text(logo.glyph).font(.custom(name, size: 16)).foregroundStyle(.white))
                .frame(width: Self.side, height: Self.side)
        } else {
            // 无 logo（Windows/RDP 或未识别）：纯色底 + 系统符号，保持实心方块风格统一。
            let bg: Color = host.isRDP ? Color(hex: 0x0078D4) : Pal.fill(0.14)
            let fg: Color = host.isRDP ? .white : Pal.subtext
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(bg)
                .overlay(Image(systemName: host.isRDP ? "display" : "server.rack")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(fg))
                .frame(width: Self.side, height: Self.side)
        }
    }
}
