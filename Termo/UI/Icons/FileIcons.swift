import SwiftUI

/// 按文件类型返回 SF Symbol 图标 + 颜色（资源管理器风格，尽量丰富地覆盖常见类型）。
/// 语言层面 SF Symbols 无品牌图标，故以「少数代码字形 + 鲜明配色」最大化区分度；
/// 另对特殊文件名、特殊目录、归档/镜像/包、密钥/字体、备份/临时/续传等做了细分。
enum FileIcon {
    // Catppuccin 强调色（按类别上色，色相尽量分散以提升辨识度）
    private static let rosewater = Color(hex: 0xf5e0dc)
    private static let flamingo  = Color(hex: 0xf2cdcd)
    private static let pink      = Color(hex: 0xf5c2e7)
    private static let mauve     = Color(hex: 0xcba6f7)
    private static let red       = Color(hex: 0xf38ba8)
    private static let maroon    = Color(hex: 0xeba0ac)
    private static let peach     = Color(hex: 0xfab387)
    private static let yellow    = Color(hex: 0xf9e2af)
    private static let green     = Color(hex: 0xa6e3a1)
    private static let teal      = Color(hex: 0x94e2d5)
    private static let sky       = Color(hex: 0x89dceb)
    private static let sapphire  = Color(hex: 0x74c7ec)
    private static let blue      = Color(hex: 0x89b4fa)
    private static let lavender  = Color(hex: 0xb4befe)

    static func info(for file: RemoteFile) -> (symbol: String, color: Color) {
        switch file.kind {
        case .directory: return dirInfo(file.name.lowercased())
        case .symlink:   return ("arrow.up.right.square", Pal.subtext)
        case .other:     return ("questionmark.square", Pal.overlay)
        case .file:      return fileInfo(file.name)
        }
    }

    /// 编程语言的 Nerd Font 字形（真实官方图标，Devicon 等；码点稳定）。返回 nil → 调用方回退 SF Symbol。
    /// 仅收录置信度高的码点，避免渲染出错误/缺失字形；其余类型留给 SF Symbol。着色仍用 info(for:) 的配色。
    static func nerdGlyph(for rawName: String) -> String? {
        var name = rawName.lowercased()
        if name.hasSuffix(".part") { name = String(name.dropLast(5)) }   // 续传残留按内层类型取字形
        let ext = (name as NSString).pathExtension
        switch ext {
        case "py", "pyw", "pyi":            return "\u{e73c}"   // Python
        case "rs":                          return "\u{e7a8}"   // Rust
        case "java", "class":               return "\u{e738}"   // Java
        case "php":                         return "\u{e73d}"   // PHP
        case "rb", "erb", "gemspec":        return "\u{e739}"   // Ruby
        case "html", "htm", "xhtml":        return "\u{e736}"   // HTML5
        case "css":                         return "\u{e749}"   // CSS3
        case "scss", "sass":                return "\u{e74b}"   // Sass
        case "md", "markdown", "mdx", "mkd":return "\u{e73e}"   // Markdown
        case "dart":                        return "\u{e798}"   // Dart
        case "cs":                          return "\u{e7b2}"   // C#
        case "c", "h":                      return "\u{e61e}"   // C
        case "cpp", "cc", "cxx", "c++", "hpp", "hxx", "h++":
                                            return "\u{e61d}"   // C++
        case "js", "mjs", "cjs":            return "\u{e781}"   // JavaScript
        case "ts":                          return "\u{e628}"   // TypeScript
        case "jsx", "tsx":                  return "\u{e7ba}"   // React
        case "kt", "kts":                   return "\u{e634}"   // Kotlin
        case "go":                          return "\u{e724}"   // Go
        case "lua":                         return "\u{e826}"   // Lua
        default:                            return nil
        }
    }

    // MARK: - 目录

    /// 常见特殊目录给予不同色调（保留文件夹形状以维持「目录」的直觉），其余用默认蓝色文件夹。
    private static func dirInfo(_ name: String) -> (String, Color) {
        switch name {
        case ".git":                                   return ("folder.fill", peach)
        case ".github", ".gitlab":                     return ("folder.fill", Pal.overlay)
        case ".ssh", ".gnupg":                         return ("folder.fill", green)
        case ".config", ".vscode", ".idea", ".settings":
                                                       return ("folder.fill", Pal.subtext)
        case "node_modules", "vendor", "venv", ".venv", "site-packages":
                                                       return ("shippingbox.fill", maroon)
        case "dist", "build", "out", "target", "bin", ".next", ".output", "release", "debug":
                                                       return ("folder.fill", Pal.subtext)
        case "src", "lib", "app", "source", "sources": return ("folder.fill", sky)
        case "assets", "public", "static", "images", "img", "media", "resources":
                                                       return ("folder.fill", teal)
        case "test", "tests", "__tests__", "spec", "specs":
                                                       return ("folder.fill", green)
        case "docs", "doc", "documentation":           return ("folder.fill", blue)
        case "snap", "packages", "pkg":                return ("shippingbox.fill", peach)
        case ".cache", "tmp", "temp", "cache":         return ("folder.fill", Pal.overlay)
        case "downloads":                              return ("folder.fill", sapphire)
        default:                                       return ("folder.fill", blue)
        }
    }

    // MARK: - 文件

    private static func fileInfo(_ rawName: String) -> (String, Color) {
        // 续传残留：剥掉 .part 后用内层类型上色（保留可辨识度，下载完成后即恢复正常名）。
        if rawName.lowercased().hasSuffix(".part") {
            return fileInfo(String(rawName.dropLast(5)))
        }
        let lower = rawName.lowercased()

        // 先按完整文件名匹配（配置、清单、许可、CI 等约定文件）
        if let hit = specialName(lower) { return hit }

        let ext = (lower as NSString).pathExtension
        switch ext {
        // 编程语言
        case "swift":                       return ("swift", peach)
        case "js", "mjs", "cjs":            return ("curlybraces", yellow)
        case "ts":                          return ("curlybraces", blue)
        case "tsx":                         return ("curlybraces", sapphire)
        case "jsx":                         return ("curlybraces", sky)
        case "py", "pyw", "pyi":            return ("chevron.left.forwardslash.chevron.right", blue)
        case "java", "class":               return ("cup.and.saucer.fill", red)
        case "kt", "kts":                   return ("chevron.left.forwardslash.chevron.right", mauve)
        case "go":                          return ("chevron.left.forwardslash.chevron.right", sky)
        case "rs":                          return ("gearshape.fill", peach)
        case "rb", "erb", "gemspec":        return ("diamond.fill", red)
        case "php":                         return ("chevron.left.forwardslash.chevron.right", lavender)
        case "c":                           return ("chevron.left.forwardslash.chevron.right", sapphire)
        case "h", "hh":                     return ("chevron.left.forwardslash.chevron.right", sky)
        case "cpp", "cc", "cxx", "c++", "hpp", "hxx", "h++":
                                            return ("chevron.left.forwardslash.chevron.right", blue)
        case "cs":                          return ("chevron.left.forwardslash.chevron.right", green)
        case "scala", "sc":                 return ("function", red)
        case "groovy", "gradle":            return ("chevron.left.forwardslash.chevron.right", teal)
        case "dart":                        return ("chevron.left.forwardslash.chevron.right", sky)
        case "lua":                         return ("moon.stars.fill", blue)
        case "pl", "pm", "perl":            return ("chevron.left.forwardslash.chevron.right", sapphire)
        case "r", "rmd":                    return ("chevron.left.forwardslash.chevron.right", blue)
        case "ex", "exs", "eex", "heex":    return ("drop.fill", mauve)
        case "erl", "hrl":                  return ("drop.fill", red)
        case "clj", "cljs", "cljc", "edn":  return ("function", green)
        case "hs", "lhs":                   return ("function", mauve)
        case "ml", "mli", "fs", "fsx", "fsi":
                                            return ("function", peach)
        case "lisp", "el", "scm", "rkt":    return ("function", blue)
        case "jl":                          return ("chevron.left.forwardslash.chevron.right", mauve)
        case "nim":                         return ("chevron.left.forwardslash.chevron.right", yellow)
        case "zig":                         return ("chevron.left.forwardslash.chevron.right", peach)
        case "v", "vala":                   return ("chevron.left.forwardslash.chevron.right", blue)
        case "asm", "s":                    return ("cpu", red)
        case "wasm":                        return ("cpu", mauve)
        case "sol":                         return ("diamond.fill", sapphire)

        // Web / 标记 / 样式
        case "html", "htm", "xhtml":        return ("chevron.left.forwardslash.chevron.right", peach)
        case "vue":                         return ("chevron.left.forwardslash.chevron.right", green)
        case "svelte", "astro":             return ("chevron.left.forwardslash.chevron.right", peach)
        case "css":                         return ("paintbrush.fill", blue)
        case "scss", "sass":                return ("paintbrush.fill", pink)
        case "less":                        return ("paintbrush.fill", sapphire)
        case "styl":                        return ("paintbrush.fill", green)
        case "xml", "xsl", "xslt", "plist", "xaml":
                                            return ("chevron.left.forwardslash.chevron.right", peach)
        case "svg":                         return ("photo.fill", peach)

        // 数据 / 配置 / 数据库
        case "json", "json5", "jsonc", "geojson", "ndjson":
                                            return ("curlybraces", yellow)
        case "yaml", "yml", "toml":         return ("gearshape.fill", peach)
        case "ini", "conf", "cfg", "cnf", "config", "properties", "editorconfig":
                                            return ("gearshape.fill", Pal.subtext)
        case "env":                         return ("gearshape.fill", yellow)
        case "sql":                         return ("cylinder.fill", blue)
        case "db", "sqlite", "sqlite3", "mdb", "accdb", "dump":
                                            return ("cylinder.split.1x2.fill", teal)
        case "csv":                         return ("tablecells", green)
        case "tsv":                         return ("tablecells", teal)
        case "parquet", "avro", "orc":      return ("tablecells.fill", sapphire)
        case "proto":                       return ("chevron.left.forwardslash.chevron.right", sky)
        case "graphql", "gql":              return ("circle.hexagongrid.fill", pink)

        // 文档
        case "md", "markdown", "mdx", "mkd": return ("text.alignleft", sky)
        case "rst", "adoc", "asciidoc":     return ("doc.text", blue)
        case "txt", "text":                 return ("doc.text", Pal.subtext)
        case "log":                         return ("list.bullet.rectangle", Pal.subtext)
        case "pdf":                         return ("doc.richtext.fill", red)
        case "doc", "docx", "rtf", "odt", "pages":
                                            return ("doc.text.fill", blue)
        case "xls", "xlsx", "ods", "numbers":
                                            return ("tablecells.fill", green)
        case "ppt", "pptx", "odp":          return ("rectangle.on.rectangle.fill", peach)
        case "epub", "mobi", "azw3", "fb2": return ("book.fill", teal)
        case "tex", "bib":                  return ("function", green)
        case "ipynb":                       return ("book.closed.fill", peach)

        // 图片
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "ico", "icns", "tiff", "tif", "heic", "heif", "avif", "jfif":
                                            return ("photo.fill", teal)
        case "psd", "ai", "xcf", "sketch", "fig", "xd":
                                            return ("paintpalette.fill", pink)
        case "raw", "cr2", "cr3", "nef", "arw", "dng", "raf":
                                            return ("camera.fill", teal)

        // 音频 / 视频 / 字幕
        case "mp3", "wav", "flac", "aac", "ogg", "m4a", "opus", "wma", "aiff", "ape":
                                            return ("music.note", pink)
        case "mid", "midi":                 return ("pianokeys", pink)
        case "mp4", "mkv", "mov", "avi", "webm", "flv", "wmv", "m4v", "mpg", "mpeg", "3gp":
                                            return ("film.fill", mauve)
        case "srt", "vtt", "ass", "ssa", "sub":
                                            return ("captions.bubble.fill", Pal.subtext)

        // 归档 / 镜像 / 包
        case "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "zst", "lz4", "lzma", "cab", "ar":
                                            return ("doc.zipper", maroon)
        case "iso", "img":                  return ("opticaldisc.fill", Pal.subtext)
        case "dmg":                         return ("opticaldisc.fill", sapphire)
        case "deb":                         return ("shippingbox.fill", red)
        case "rpm":                         return ("shippingbox.fill", blue)
        case "apk", "aab":                  return ("shippingbox.fill", green)
        case "ipa":                         return ("app.badge.fill", blue)
        case "appimage", "snap", "flatpak": return ("shippingbox.fill", yellow)
        case "exe", "msi":                  return ("app.badge.fill", sapphire)
        case "app":                         return ("app.fill", blue)
        case "jar", "war":                  return ("cup.and.saucer.fill", maroon)
        case "whl", "egg":                  return ("shippingbox.fill", blue)
        case "gem":                         return ("diamond.fill", red)
        case "crate":                       return ("shippingbox.fill", peach)

        // 密钥 / 证书
        case "pem", "key", "crt", "cert", "cer", "pub", "p12", "pfx", "asc", "gpg", "pgp", "kdbx", "keystore", "jks":
                                            return ("key.fill", yellow)

        // 字体
        case "ttf", "otf", "woff", "woff2", "eot", "ttc":
                                            return ("textformat", lavender)

        // Shell / 脚本
        case "sh", "bash", "zsh", "fish", "ksh":
                                            return ("terminal.fill", green)
        case "bat", "cmd", "ps1", "psm1":   return ("terminal.fill", sapphire)
        case "awk", "sed":                  return ("terminal.fill", teal)

        // 二进制 / 库
        case "so", "dylib", "dll", "o", "a", "lib", "bin", "out", "elf", "ko", "obj":
                                            return ("gearshape.2.fill", Pal.overlay)

        // 补丁 / 备份 / 临时 / 锁
        case "patch", "diff":               return ("plusminus.circle.fill", green)
        case "bak", "old", "orig":          return ("clock.arrow.circlepath", Pal.overlay)
        case "tmp", "temp", "swp", "swo":   return ("hourglass", Pal.overlay)
        case "lock":                        return ("lock.fill", Pal.overlay)

        default:
            return ("doc", Pal.overlay)
        }
    }

    /// 按完整文件名匹配的约定文件（优先于扩展名）。
    private static func specialName(_ lower: String) -> (String, Color)? {
        switch lower {
        case "dockerfile", "containerfile", ".dockerignore":
            return ("shippingbox.fill", blue)
        case "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml":
            return ("shippingbox.fill", sky)
        case "makefile", "gnumakefile", "cmakelists.txt":
            return ("hammer.fill", peach)
        case "build.gradle", "build.gradle.kts", "pom.xml", "build.xml", "vagrantfile":
            return ("hammer.fill", teal)
        case ".gitignore", ".gitattributes", ".gitmodules", ".gitkeep":
            return ("arrow.triangle.branch", peach)
        case ".npmrc", ".nvmrc", ".yarnrc":
            return ("shippingbox.fill", red)
        case ".prettierrc", ".eslintrc", ".babelrc", ".stylelintrc", ".editorconfig":
            return ("gearshape.fill", yellow)
        case ".env", ".env.local", ".env.development", ".env.production", ".env.test":
            return ("gearshape.fill", yellow)
        case ".bashrc", ".bash_profile", ".bash_history", ".zshrc", ".profile", ".vimrc", ".viminfo", ".inputrc":
            return ("gearshape.fill", Pal.subtext)
        case "license", "license.txt", "license.md", "licence", "copying", "copying.txt":
            return ("checkmark.seal.fill", yellow)
        case "readme", "readme.md", "readme.txt", "readme.rst":
            return ("book.fill", blue)
        case "changelog", "changelog.md", "history.md":
            return ("clock.fill", blue)
        case "contributing", "contributing.md", "code_of_conduct.md":
            return ("person.2.fill", green)
        case "authors", "codeowners", ".mailmap":
            return ("person.fill", Pal.subtext)
        case "todo", "todo.md", "todo.txt":
            return ("checklist", yellow)
        case "package.json":          return ("shippingbox.fill", red)
        case "composer.json":         return ("shippingbox.fill", lavender)
        case "cargo.toml":            return ("shippingbox.fill", peach)
        case "go.mod":                return ("shippingbox.fill", sky)
        case "pubspec.yaml":          return ("shippingbox.fill", sky)
        case "gemfile", "rakefile":   return ("diamond.fill", red)
        case "pipfile", "requirements.txt", "setup.py", "pyproject.toml":
            return ("shippingbox.fill", blue)
        case "procfile":              return ("gearshape.fill", mauve)
        case "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock",
             "composer.lock", "go.sum", "gemfile.lock", "poetry.lock", "pipfile.lock":
            return ("lock.fill", Pal.overlay)
        case "authorized_keys", "known_hosts", "id_rsa", "id_ed25519", "id_ecdsa":
            return ("key.fill", yellow)
        default:
            return nil
        }
    }
}
