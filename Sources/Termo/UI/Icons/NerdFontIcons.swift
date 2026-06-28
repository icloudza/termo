import AppKit
import CoreText
import SwiftUI

/// Nerd Font 探测：用于渲染编程语言的「真实官方图标」字形（Devicon 等）。
/// SF Symbols 无各语言官方 logo（仅 Swift），故文件类型图标优先用 Nerd Font 字形，缺字体则回退 SF Symbol。
///
/// 取用顺序：先尝试注册放在 Resources 里的 Nerd Font（用户可自带打包），再在系统已安装字体中挑一个可用的。
/// 字形为单色，按品牌色着色（颜色取 FileIcon 配色）。
enum NerdFont {
    // 常见 Nerd Font 名称（都含 Devicon 字形，码点一致）。Symbols 系列最纯净，优先。
    private static let candidates = [
        "Symbols Nerd Font Mono", "Symbols Nerd Font",
        "JetBrainsMono Nerd Font", "JetBrainsMonoNL Nerd Font",
        "FiraCode Nerd Font", "MesloLGM Nerd Font", "MesloLGS Nerd Font",
        "Hack Nerd Font", "CaskaydiaCove Nerd Font", "SauceCodePro Nerd Font",
        "Iosevka Nerd Font", "UbuntuMono Nerd Font",
    ]

    private static var didSetup = false
    private static var resolvedName: String?

    /// 当前可用的 Nerd Font 字体名（nil = 未安装也未打包，调用方回退 SF Symbol）。首次访问惰性初始化。
    static var name: String? {
        if !didSetup { setup() }
        return resolvedName
    }
    static var isAvailable: Bool { name != nil }

    /// 解析可用字体名（仅一次）。优先注册 Resources 里打包的 Nerd Font（免安装即可用，与 OSLogo 同法）；
    /// 没打包则在系统已安装字体里找任意一个 Nerd Font。首个图标渲染时在主线程惰性触发，只跑一遍。
    static func setup() {
        didSetup = true
        if let bundled = registerBundledNerdFont() { resolvedName = bundled; return }

        // 枚举系统已安装字体，挑名字含 "Nerd Font" 的任意一个——比固定候选名稳健，
        // 不管用户装的是哪款 Nerd Font（JetBrainsMono/FiraCode/Symbols…）都能命中。
        let mgr = NSFontManager.shared
        if let fam = mgr.availableFontFamilies.first(where: {
            $0.range(of: "Nerd Font", options: .caseInsensitive) != nil
        }), NSFont(name: fam, size: 12) != nil {
            resolvedName = fam; return
        }
        if let ps = mgr.availableFonts.first(where: {
            $0.range(of: "NerdFont", options: .caseInsensitive) != nil
            || $0.range(of: "Nerd Font", options: .caseInsensitive) != nil
        }) {
            resolvedName = ps; return
        }
        // 兜底：固定候选名（极少数枚举不到的情况）
        resolvedName = candidates.first { NSFont(name: $0, size: 12) != nil }
    }

    // 字形拟合字号缓存：不同 Nerd Font 字形在字面框内的设计大小不一，逐字形按包围盒反算字号，使视觉大小统一。
    private static var fitCache: [String: CGFloat] = [:]

    /// 让某字形的视觉尺寸（包围盒较长边）约等于 `box` 点；返回应使用的字号（带缓存与上下限保护）。
    static func fittedSize(glyph: String, box: CGFloat) -> CGFloat {
        guard let fontName = name, let scalar = glyph.unicodeScalars.first else { return box }
        let key = "\(scalar.value)@\(Int(box * 10))"
        if let c = fitCache[key] { return c }

        let probe: CGFloat = 100
        guard let font = NSFont(name: fontName, size: probe) else { fitCache[key] = box; return box }
        var chars = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
              let g = glyphs.first, g != 0 else { fitCache[key] = box; return box }
        var gid = g
        let rect = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &gid, nil, 1)
        let dim = max(rect.width, rect.height)
        // 较长边拟合到 box；夹在 [0.75, 1.9]×box 之间，避免个别字形被放得过大/过小。
        let fitted = dim > 0 ? min(max(box * probe / dim, box * 0.75), box * 1.9) : box
        fitCache[key] = fitted
        return fitted
    }

    /// 注册 Resources 里文件名含 "nerd" 的字体并返回其 PostScript 名（供 `.custom` 渲染）；无则 nil。
    private static func registerBundledNerdFont() -> String? {
        for ext in ["ttf", "otf"] {
            let urls = Bundle.module.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
            for u in urls where u.lastPathComponent.lowercased().contains("nerd") {
                guard let provider = CGDataProvider(url: u as CFURL), let cg = CGFont(provider) else { continue }
                CTFontManagerRegisterGraphicsFont(cg, nil)
                if let ps = cg.postScriptName as String? { return ps }
            }
        }
        return nil
    }
}

/// 统一的文件类型图标：装了 Nerd Font 且该文件类型有对应字形时渲染真实语言官方图标，否则回退 SF Symbol。
/// 颜色一致（均取 FileIcon 配色）。左侧文件树、文件浏览器、编辑器面包屑/标题共用此视图。
struct FileTypeIcon: View {
    let file: RemoteFile
    var size: CGFloat = 13

    var body: some View {
        let ic = FileIcon.info(for: file)
        if file.kind == .file, let fontName = NerdFont.name, let glyph = FileIcon.nerdGlyph(for: file.name) {
            // 视觉盒子略大于字号；逐字形拟合字号，使大小不一的 Nerd Font 字形看起来统一、居中。
            let box = size * 1.08
            Text(glyph)
                .font(.custom(fontName, size: NerdFont.fittedSize(glyph: glyph, box: box)))
                .foregroundStyle(ic.color)
                .frame(width: box, height: box)
        } else {
            Image(systemName: ic.symbol)
                .font(.system(size: size))
                .foregroundStyle(ic.color)
        }
    }
}
