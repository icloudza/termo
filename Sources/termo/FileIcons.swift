import SwiftUI

/// 按文件类型返回 SF Symbol 图标 + 颜色（VS Code 资源管理器风格，覆盖绝大多数常见类型）。
enum FileIcon {
    // Catppuccin 强调色（按文件类别上色）
    private static let blue = Color(hex: 0x89b4fa)
    private static let sapphire = Color(hex: 0x74c7ec)
    private static let sky = Color(hex: 0x89dceb)
    private static let teal = Color(hex: 0x94e2d5)
    private static let green = Color(hex: 0xa6e3a1)
    private static let yellow = Color(hex: 0xf9e2af)
    private static let peach = Color(hex: 0xfab387)
    private static let maroon = Color(hex: 0xeba0ac)
    private static let red = Color(hex: 0xf38ba8)
    private static let pink = Color(hex: 0xf5c2e7)
    private static let mauve = Color(hex: 0xcba6f7)

    static func info(for file: RemoteFile) -> (symbol: String, color: Color) {
        switch file.kind {
        case .directory: return ("folder.fill", blue)
        case .symlink: return ("arrow.up.right.square", Pal.subtext)
        case .other: return ("questionmark.square", Pal.overlay)
        case .file: return fileInfo(file.name)
        }
    }

    private static func fileInfo(_ name: String) -> (String, Color) {
        let lower = name.lowercased()
        // 先按特殊文件名匹配
        switch lower {
        case "dockerfile", ".dockerignore": return ("shippingbox.fill", blue)
        case "makefile", "cmakelists.txt": return ("hammer.fill", peach)
        case ".gitignore", ".gitattributes", ".gitmodules": return ("arrow.triangle.branch", peach)
        case ".env", ".env.local", ".env.production": return ("gearshape.fill", yellow)
        case "license", "license.txt", "license.md", "copying": return ("checkmark.seal.fill", yellow)
        case "readme", "readme.md", "readme.txt": return ("book.fill", blue)
        case "package.json": return ("shippingbox.fill", red)
        case "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "composer.lock", "go.sum":
            return ("lock.fill", Pal.overlay)
        default: break
        }

        let ext = (lower as NSString).pathExtension
        switch ext {
        // 编程语言
        case "swift": return ("swift", peach)
        case "js", "mjs", "cjs": return ("curlybraces", yellow)
        case "ts", "tsx": return ("curlybraces", blue)
        case "jsx": return ("curlybraces", sky)
        case "py", "pyw", "pyi": return ("chevron.left.forwardslash.chevron.right", blue)
        case "java", "class", "jar": return ("cup.and.saucer.fill", red)
        case "kt", "kts": return ("chevron.left.forwardslash.chevron.right", peach)
        case "go": return ("chevron.left.forwardslash.chevron.right", sky)
        case "rs": return ("gearshape.fill", peach)
        case "rb": return ("chevron.left.forwardslash.chevron.right", red)
        case "php": return ("chevron.left.forwardslash.chevron.right", mauve)
        case "c", "h": return ("chevron.left.forwardslash.chevron.right", blue)
        case "cpp", "cc", "cxx", "hpp", "hxx": return ("chevron.left.forwardslash.chevron.right", sapphire)
        case "cs": return ("chevron.left.forwardslash.chevron.right", green)
        case "scala", "groovy", "dart", "lua", "perl", "pl", "r", "ex", "exs", "clj":
            return ("chevron.left.forwardslash.chevron.right", mauve)
        // Web / 样式
        case "html", "htm", "xhtml", "vue", "svelte", "astro": return ("chevron.left.forwardslash.chevron.right", peach)
        case "css", "scss", "sass", "less", "styl": return ("paintbrush.fill", blue)
        case "xml", "xsl", "svg": return ("chevron.left.forwardslash.chevron.right", peach)
        // 数据 / 配置
        case "json", "json5", "jsonc": return ("curlybraces", yellow)
        case "yaml", "yml", "toml", "ini", "conf", "cfg", "properties", "env":
            return ("gearshape.fill", Pal.subtext)
        case "sql": return ("cylinder.fill", blue)
        case "db", "sqlite", "sqlite3": return ("cylinder.split.1x2.fill", teal)
        case "csv", "tsv": return ("tablecells", green)
        // 文档
        case "md", "markdown", "mdx": return ("text.alignleft", blue)
        case "txt", "text": return ("doc.text", Pal.subtext)
        case "log": return ("list.bullet.rectangle", Pal.subtext)
        case "pdf": return ("doc.richtext.fill", red)
        case "doc", "docx", "rtf", "odt": return ("doc.text.fill", blue)
        case "xls", "xlsx", "ods": return ("tablecells.fill", green)
        case "ppt", "pptx", "odp": return ("rectangle.on.rectangle.fill", peach)
        // 图片
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "ico", "tiff", "tif", "heic", "avif":
            return ("photo.fill", teal)
        // 音视频
        case "mp3", "wav", "flac", "aac", "ogg", "m4a", "opus", "wma": return ("music.note", pink)
        case "mp4", "mkv", "mov", "avi", "webm", "flv", "wmv", "m4v": return ("film.fill", pink)
        // 压缩 / 镜像
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "lz4":
            return ("doc.zipper", red)
        case "iso", "img", "dmg": return ("opticaldisc.fill", Pal.subtext)
        // 密钥 / 证书
        case "pem", "key", "crt", "cert", "cer", "pub", "p12", "pfx", "asc":
            return ("key.fill", yellow)
        // 字体
        case "ttf", "otf", "woff", "woff2", "eot": return ("textformat", Pal.subtext)
        // Shell / 脚本
        case "sh", "bash", "zsh", "fish", "bat", "cmd", "ps1": return ("terminal.fill", green)
        // 二进制 / 库
        case "so", "dylib", "dll", "o", "a", "lib", "exe", "bin", "out":
            return ("gearshape.2.fill", Pal.overlay)
        default:
            return ("doc", Pal.overlay)
        }
    }
}
