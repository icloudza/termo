import AppKit
import SwiftUI

/// 编辑器/预览的内容形态。
enum ViewerMode: Equatable {
    case text          // 可编辑文本
    case readonlyText  // 强制按文本打开的二进制（只读，避免保存损坏）
    case image
    case binary        // 二进制，提供「强制按文本打开」
    case tooLarge
}

/// 单个文件编辑/预览标签的状态（每标签一份，AppModel 缓存）。
@MainActor
final class EditorState: ObservableObject {
    let file: RemoteFile
    let host: Host
    private let fs: RemoteFS

    @Published var phase: LoadPhase = .loading
    @Published var mode: ViewerMode = .text
    @Published var text: String = "" { didSet { isDirty = (text != savedText) } }
    @Published var isDirty = false
    @Published var saving = false
    @Published var saveError: String? = nil
    @Published var image: NSImage? = nil
    @Published var byteSize: Int64 = 0
    @Published var formatting = false

    private var savedText = ""
    private var rawData = Data()           // 二进制强制打开时用
    private var loadTask: Task<Void, Never>?
    private var started = false

    // 上限：文本 2MB，图片 16MB
    private let textLimit = 2_000_000
    private let imageLimit = 16_000_000

    var canSave: Bool { (mode == .text) && isDirty && !saving }
    var canFormat: Bool { mode == .text && !formatting && Self.formatterCommand(for: file.name) != nil }
    var lineCount: Int {
        guard !text.isEmpty else { return 1 }
        return text.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    init(file: RemoteFile, host: Host, fs: RemoteFS) {
        self.file = file
        self.host = host
        self.fs = fs
    }

    /// 首次出现时加载一次（openFile 与 onAppear 都可调用，幂等）。
    func loadIfNeeded() {
        guard !started else { return }
        load()
    }

    func load() {
        started = true
        loadTask?.cancel()
        phase = .loading
        saveError = nil
        let isImg = Self.isImageName(file.name)
        let limit = isImg ? imageLimit : textLimit
        loadTask = Task {
            let result = await fs.read(file.path, limit: limit + 1)
            if Task.isCancelled { return }
            switch result {
            case .failure(let e):
                phase = .error(e.message)
            case .success(let data):
                byteSize = file.size > 0 ? file.size : Int64(data.count)
                if data.count > limit {
                    mode = .tooLarge
                    phase = .loaded
                    return
                }
                rawData = data
                if isImg {
                    if let img = NSImage(data: data) {
                        image = img; mode = .image
                    } else {
                        mode = .binary   // 扩展名是图片但解码失败
                    }
                } else if let str = Self.decodeText(data) {
                    savedText = str
                    text = str
                    isDirty = false
                    mode = .text
                } else {
                    mode = .binary
                }
                phase = .loaded
            }
        }
    }

    /// 二进制 → 强制按文本（有损解码）只读打开。
    func forceOpenAsText() {
        let str = String(decoding: rawData, as: UTF8.self)
        savedText = str
        text = str
        isDirty = false
        mode = .readonlyText
    }

    func reload() { load() }

    func save() {
        guard canSave else { return }
        saving = true
        saveError = nil
        let path = file.path
        let payload = Data(text.utf8)
        let snapshot = text
        Task {
            let r = await fs.write(path, data: payload)
            saving = false
            switch r {
            case .success:
                savedText = snapshot
                isDirty = (text != savedText)
            case .failure(let e):
                saveError = e.message
            }
        }
    }

    /// 整篇格式化：把 buffer 经 stdin 喂给远端格式化器，stdout 回写。失败/未安装则提示。
    func format() {
        guard canFormat, let cmd = Self.formatterCommand(for: file.name) else { return }
        formatting = true
        saveError = nil
        let payload = Data(text.utf8)
        let snapshot = text
        Task {
            let r = await fs.run(cmd, stdin: payload, timeout: 30)
            formatting = false
            let out = String(data: r.data, encoding: .utf8) ?? ""
            if r.code == 0, !out.isEmpty {
                if out != snapshot { text = out }   // didSet 标脏
            } else {
                let err = (String(data: r.stderr, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if err.contains("command not found") || err.contains("not found") || r.code == 127 {
                    saveError = "远端未安装该格式化工具"
                } else if !err.isEmpty {
                    saveError = "格式化失败：" + String(err.prefix(100))
                } else {
                    saveError = "格式化失败（退出码 \(r.code)）"
                }
            }
        }
    }

    func cancel() { loadTask?.cancel() }

    // MARK: - 工具

    /// 按文件类型返回「读 stdin、写 stdout」的远端格式化命令；不支持则 nil。
    static func formatterCommand(for name: String) -> String? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        // 安全单引号包裹文件名（供 prettier 推断 parser）
        let quoted = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch ext {
        case "go": return "gofmt"
        case "py", "pyi": return "black -q - 2>/dev/null"
        case "rs": return "rustfmt --emit=stdout 2>/dev/null"
        case "c", "h", "cpp", "cc", "cxx", "hpp", "hxx", "m", "mm": return "clang-format"
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "json", "json5",
             "css", "scss", "less", "html", "vue", "yaml", "yml", "md", "markdown":
            return "prettier --stdin-filepath \(quoted)"
        default: return nil
        }
    }

    static func isImageName(_ name: String) -> Bool {
        let ext = (name.lowercased() as NSString).pathExtension
        return ["png","jpg","jpeg","gif","bmp","webp","ico","tiff","tif","heic","heif"].contains(ext)
    }

    /// 尝试把字节解码为文本：含 NUL 或非 UTF-8 视为二进制。
    static func decodeText(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        // 前 8KB 出现 NUL 基本可判为二进制
        let probe = data.prefix(8192)
        if probe.contains(0) { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        // 退而求其次：GBK/Latin1 常见于旧文件
        if let s = String(data: data, encoding: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) { return s }
        return nil
    }
}

// MARK: - 路由视图

/// 头部（标题/面包屑）左缩进：让内容左缘越过编辑器行号栏，与代码正文对齐。
/// 行号栏宽度随行数位数变化（约 38–52px），取 46 覆盖常见 2–4 位行号。
private let editorHeaderInset: CGFloat = 14

struct FileViewerView: View {
    @ObservedObject var state: EditorState
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            EditorBreadcrumb(file: state.file, host: state.host, model: model)
            content
                // 裁到自身框内：防止滚动时行号栏(gutter)向上溢出盖到头部/面包屑
                .clipped()
                // 分割线画在编辑器内容「之上」(overlay)，避免滚动时被行号栏背景重绘盖掉
                .overlay(alignment: .top) {
                    Rectangle().fill(Pal.fill(0.08)).frame(height: 1)
                }
        }
        .background(Pal.base)
        .onAppear { state.loadIfNeeded() }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            let ic = FileIcon.info(for: state.file)
            Image(systemName: ic.symbol).font(.system(size: 13)).foregroundStyle(ic.color)
            Text(state.file.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                .lineLimit(1)
            if state.isDirty {
                Circle().fill(Pal.yellow).frame(width: 6, height: 6)
            }

            Spacer(minLength: 8)

            if let err = state.saveError {
                Text(err).font(.system(size: 11)).foregroundStyle(Pal.red)
                    .lineLimit(1).truncationMode(.middle)
            }

            switch state.mode {
            case .text, .readonlyText:
                Text("\(state.lineCount) 行").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Text(humanSize(state.byteSize)).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            case .image:
                if let img = state.image {
                    Text("\(Int(img.size.width))×\(Int(img.size.height))")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                Text(humanSize(state.byteSize)).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            default:
                EmptyView()
            }

            if state.mode == .text || state.mode == .readonlyText {
                Button { settings.editorMinimap.toggle() } label: {
                    Image(systemName: "map")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(settings.editorMinimap ? Pal.mauve : Pal.overlay)
                        .frame(width: 26, height: 26)
                        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(settings.editorMinimap ? "隐藏缩略图" : "显示缩略图")
            }

            if state.mode == .text, EditorState.formatterCommand(for: state.file.name) != nil {
                Button { state.format() } label: {
                    Group {
                        if state.formatting { ProgressView().controlSize(.small).scaleEffect(0.6) }
                        else { Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .medium)) }
                    }
                    .foregroundStyle(state.canFormat ? Pal.mauve : Pal.overlay)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!state.canFormat)
                .keyboardShortcut("f", modifiers: [.option, .shift])
                .help("格式化（远端 gofmt/black/prettier 等）")
            }

            iconButton("arrow.clockwise", help: "重新加载") { state.reload() }

            if state.mode == .text {
                Button { state.save() } label: {
                    HStack(spacing: 5) {
                        if state.saving { ProgressView().controlSize(.small).scaleEffect(0.7) }
                        else { Image(systemName: "square.and.arrow.down").font(.system(size: 11, weight: .semibold)) }
                        Text("保存").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(state.canSave ? Pal.mauve : Pal.overlay.opacity(0.5))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(state.canSave ? Pal.mauve.opacity(0.12) : Pal.fill(0.04),
                                in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!state.canSave)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.leading, editorHeaderInset).padding(.trailing, 12).padding(.vertical, 6)
    }

    private func iconButton(_ symbol: String, help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .loading:
            centered { ProgressView().controlSize(.small) }
        case .error(let msg):
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 24)).foregroundStyle(Pal.yellow)
                    Text(msg).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                    Button("重试") { state.reload() }.buttonStyle(.plain).foregroundStyle(Pal.mauve)
                }
                .padding(.horizontal, 40)
            }
        case .loaded:
            switch state.mode {
            case .text, .readonlyText:
                RemoteCodeEditor(
                    text: $state.text,
                    editable: state.mode == .text,
                    fileName: state.file.name,
                    colors: theme.colors,
                    isDark: theme.isDark,
                    font: Self.editorFont,
                    showMinimap: settings.editorMinimap
                )
            case .image:
                ImagePreviewView(image: state.image)
            case .binary:
                BinaryNoticeView(file: state.file, size: state.byteSize,
                                 onForceText: { state.forceOpenAsText() })
            case .tooLarge:
                TooLargeNoticeView(size: state.byteSize)
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static let editorFont: NSFont = {
        let size: CGFloat = 13
        // 用干净等宽字体（Nerd Font 的 leading/行间距过大，会让空行光标行变高两倍）。
        // 代码编辑器不需要 Nerd 图标，优先 SF Mono / JetBrains Mono / Menlo。
        for name in ["SF Mono", "JetBrains Mono", "JetBrainsMono-Regular", "Menlo", "Monaco"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }()
}

// MARK: - 面包屑路径条（Xcode jump bar 风，可点击跳转左侧资源管理器）

private struct EditorBreadcrumb: View {
    let file: RemoteFile
    let host: Host
    @ObservedObject var model: AppModel

    private struct Crumb: Identifiable {
        let id: Int
        let name: String
        let path: String
        let isLast: Bool
    }

    private var crumbs: [Crumb] {
        let comps = file.path.split(separator: "/").map(String.init)
        var acc = ""
        var out: [Crumb] = []
        for (i, c) in comps.enumerated() {
            acc += "/" + c
            out.append(Crumb(id: i, name: c, path: acc, isLast: i == comps.count - 1))
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    // 主机/工作区：单独的小胶囊标签，与目录区分
                    HostPill(name: host.name) { model.jumpToExplorer(path: "/", host: host) }
                    ForEach(crumbs) { crumb in
                        HStack(spacing: 5) {
                            Text("/").font(.system(size: 11)).foregroundStyle(Pal.overlay.opacity(0.4))
                            CrumbText(name: crumb.name, isLast: crumb.isLast, file: file) {
                                model.jumpToExplorer(path: crumb.path, host: host)
                            }
                        }
                        .id(crumb.id)
                    }
                }
                .padding(.leading, editorHeaderInset).padding(.trailing, 12)
                .frame(maxHeight: .infinity)
            }
            .onAppear {
                if let last = crumbs.last { proxy.scrollTo(last.id, anchor: .trailing) }
            }
        }
        .frame(height: 28)
    }
}

/// 主机/工作区标识：小胶囊，权重高于目录、与之区分。
private struct HostPill: View {
    let name: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "server.rack").font(.system(size: 9))
                Text(name).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Pal.mauve)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Pal.mauve.opacity(hover ? 0.22 : 0.13), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("跳到根目录")
    }
}

/// 路径段：中间目录为浅灰纯文字（无图标）；末段（当前文件）带类型图标并用主文字色强调。
private struct CrumbText: View {
    let name: String
    let isLast: Bool
    let file: RemoteFile
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLast {
                    let ic = FileIcon.info(for: file)
                    Image(systemName: ic.symbol).font(.system(size: 10)).foregroundStyle(ic.color)
                }
                Text(name)
                    .font(.system(size: 11, weight: isLast ? .medium : .regular))
                    .foregroundStyle(isLast ? Pal.text : (hover ? Pal.subtext : Pal.overlay))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(hover ? Pal.fill(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(isLast ? "在文件树中定位" : "跳转到此目录")
    }
}

// MARK: - 图片预览

private struct ImagePreviewView: View {
    let image: NSImage?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CheckerboardBackground()
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .padding(20)
                    }
                } else {
                    Text("无法显示图片").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 缩放控制条
            HStack(spacing: 14) {
                zoomButton("minus.magnifyingglass") { scale = max(0.1, scale - 0.25) }
                Text("\(Int(scale * 100))%").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Pal.subtext).frame(width: 52)
                zoomButton("plus.magnifyingglass") { scale = min(8, scale + 0.25) }
                Divider().frame(height: 14).overlay(Pal.fill(0.1))
                Button("实际大小") { scale = 1.0 }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Pal.mauve)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Pal.mantle)
        }
    }

    private func zoomButton(_ symbol: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Pal.subtext)
                .frame(width: 28, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// 透明背景棋盘格。
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            let cols = Int(size.width / s) + 1
            let rows = Int(size.height / s) + 1
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    let rect = CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s, height: s)
                    ctx.fill(Path(rect), with: .color(Pal.fill(0.04)))
                }
            }
        }
        .background(Pal.base)
    }
}

// MARK: - 二进制 / 超大提示

private struct BinaryNoticeView: View {
    let file: RemoteFile
    let size: Int64
    let onForceText: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark").font(.system(size: 34)).foregroundStyle(Pal.overlay)
            Text("二进制文件").font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.text)
            Text("\(file.name) · \(humanSize(size))")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
            Button(action: onForceText) {
                Text("仍然以文本方式打开").font(.system(size: 12))
                    .foregroundStyle(Pal.mauve)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Pal.mauve.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TooLargeNoticeView: View {
    let size: Int64
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").font(.system(size: 32)).foregroundStyle(Pal.yellow)
            Text("文件过大").font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.text)
            Text("\(humanSize(size)) — 超出编辑器的打开上限")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
