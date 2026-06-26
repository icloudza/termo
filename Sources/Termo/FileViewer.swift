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
    @Published private(set) var file: RemoteFile   // 可被重命名同步更新（面包屑/语言识别/保存目标都跟随）
    let host: Host
    private let fs: RemoteFS

    /// 文件被重命名后改绑到新路径（内容不变、不重新加载；后续保存写到新路径）。
    func rebind(to newFile: RemoteFile) { file = newFile }

    @Published var phase: LoadPhase = .loading
    @Published var mode: ViewerMode = .text
    @Published var text: String = "" {
        didSet { isDirty = (text != savedText) }
    }
    @Published var isDirty = false
    /// 「基准（上次保存/加载的内容）」的版本号。每次基准变化 +1；编辑器的变更竖条协调器据此从 TextView
    /// 实时快照新基准并对账。改动竖条本身完全由编辑器侧的 ChangeBarCoordinator 按字符偏移锚定计算，
    /// 不走滞后的行号管线（彻底消除快速编辑时的错位）。
    @Published private(set) var savedVersion = 0
    @Published var saving = false
    @Published var saveError: String? = nil
    /// 保存时检测到文件已被外部修改（乐观锁冲突）→ 弹窗让用户选 覆盖/重新加载/取消。
    @Published var saveConflict = false
    @Published var image: NSImage? = nil
    @Published var byteSize: Int64 = 0

    private var savedText = ""
    /// 文件版本令牌（`mtime:size`），打开时记录、保存成功后更新；保存前据此做冲突检测。nil=该文件无法 stat（不检测）。
    private var fileVersion: String?
    /// 编辑器文本视图（弱引用）：tab keep-alive 后由 AppModel.focusActiveTab 在切到本 tab 时聚焦它。
    weak var focusView: NSView?
    private var rawData = Data()           // 二进制强制打开时用
    private var loadTask: Task<Void, Never>?
    private var started = false

    // 上限：文本 5MB，图片 16MB
    private let textLimit = 5_000_000
    private let imageLimit = 16_000_000

    var canSave: Bool { (mode == .text) && isDirty && !saving }
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
            case .success(let (data, version)):
                byteSize = file.size > 0 ? file.size : Int64(data.count)
                fileVersion = version            // 记录基准版本（乐观锁）
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
                    savedVersion &+= 1   // 新基准 → 通知协调器重设基准
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
        savedVersion &+= 1
        mode = .readonlyText
    }

    func reload() { load() }

    /// 保存。`force=true` 时跳过版本比对，强制覆盖（用于冲突弹窗里用户选「覆盖」）。
    func save(force: Bool = false) {
        guard canSave else { return }
        saving = true
        saveError = nil
        let path = file.path
        let payload = Data(text.utf8)
        let snapshot = text
        let expected = force ? nil : fileVersion
        Task {
            let r = await fs.write(path, data: payload, expectedVersion: expected)
            saving = false
            switch r {
            case .success(let newVersion):
                savedText = snapshot
                fileVersion = newVersion.isEmpty ? nil : newVersion
                isDirty = (text != savedText)
                savedVersion &+= 1   // 保存后基准更新 → 协调器重设基准并清空/重算改动竖条
            case .failure(let e):
                if e.isConflict { saveConflict = true; return }   // 弹窗交给视图，不当普通错误
                saveError = e.message
            }
        }
    }

    func cancel() { loadTask?.cancel() }

    // MARK: - 工具

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
/// 行号栏宽度随行数位数变化（约 38–52px），此缩进覆盖常见 2–4 位行号。
private let editorHeaderInset: CGFloat = 14

struct FileViewerView: View {
    @ObservedObject var state: EditorState
    @ObservedObject var model: AppModel
    let tabId: Int
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
        // 乐观锁冲突：保存时发现文件已被外部修改 → 自定义弹窗让用户选覆盖/重载/取消（避免静默丢数据）
        .overlay {
            if state.saveConflict {
                SaveConflictDialog(
                    onOverwrite: { state.saveConflict = false; state.save(force: true) },
                    onReload: { state.saveConflict = false; state.reload() },
                    onCancel: { state.saveConflict = false }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: state.saveConflict)
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
                // 编辑器实例由模型按 tab 缓存（NSHostingView 托管一次），SwiftUI 再重算也不会重建控制器
                // → 撤销栈/光标/滚动整个 tab 生命周期存活（避免 setText 清栈丢历史）。
                CachedEditorHost(model: model, tabId: tabId, state: state)
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
        let size: CGFloat = 12
        // 用 SF Mono：NSFont(name:) 取不到家族名时回退 monospacedSystemFont —— 它在现代 macOS 上本身就是 SF Mono。
        for name in ["SF Mono", "SFMono-Regular"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }()
}

/// 把单个编辑器子树用 `NSHostingView` 托管一次、按 tabId 缓存在 `AppModel`（根治撤销/状态丢失）。
/// `makeNSView` 永远返回缓存实例 → 外层 SwiftUI 再怎么重算/重建本 representable，内部
/// `TextViewController`（连同 `CEUndoManager` 撤销栈、光标、滚动）都不会被重建/清栈，整 tab 生命周期存活。
private struct CachedEditorHost: NSViewRepresentable {
    let model: AppModel
    let tabId: Int
    let state: EditorState

    func makeNSView(context: Context) -> NSView {
        if let cached = model.editorHosts[tabId] { return cached }
        let container = NSView()
        let host = NSHostingView(rootView: EditorRoot(state: state))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        model.editorHosts[tabId] = container
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 编辑器根视图（被托管一次）：内部观察 theme/settings/state，以响应主题切换、缩略图开关、文本/基准变化，
/// 全程不依赖外层重建。
private struct EditorRoot: View {
    @ObservedObject var state: EditorState
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        RemoteCodeEditor(
            text: $state.text,
            editable: state.mode == .text,
            fileName: state.file.name,
            colors: theme.colors,
            isDark: theme.isDark,
            font: FileViewerView.editorFont,
            showMinimap: settings.editorMinimap,
            savedVersion: state.savedVersion,
            onEditorReady: { [weak state] v in state?.focusView = v }
        )
    }
}

// MARK: - 面包屑路径条（可点击跳转左侧资源管理器）

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
                        HStack(spacing: 4) {
                            Text("/").font(.system(size: 10.5)).foregroundStyle(Pal.overlay.opacity(0.4))
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
        .frame(height: 22)
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
                    Image(systemName: ic.symbol).font(.system(size: 9.5)).foregroundStyle(ic.color)
                }
                Text(name)
                    .font(.system(size: 10.5, weight: isLast ? .medium : .regular))
                    .foregroundStyle(isLast ? Pal.text : (hover ? Pal.subtext : Pal.overlay))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4).padding(.vertical, 1.5)
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

/// 乐观锁冲突弹窗（自定义样式，对齐 [[HostKeyDialog]] 的卡片风，替代系统 .alert）。
/// 紧凑卡片 + 底部一排 pill 按钮，克制用色：覆盖=淡红、重载=灰底、取消=纯文字。
struct SaveConflictDialog: View {
    let onOverwrite: () -> Void
    let onReload: () -> Void
    let onCancel: () -> Void
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hovered: Int? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(theme.isDark ? 0.42 : 0.20).ignoresSafeArea()
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(Pal.yellow)
                    Text("文件已被外部修改")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    Spacer()
                }
                .padding(.bottom, 9)

                Text("该文件自你打开后，已被其他程序或会话修改。「覆盖」会丢弃外部改动，「重新加载」会丢弃你未保存的修改。")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
                    .padding(.bottom, 18)

                HStack(spacing: 8) {
                    Spacer()
                    pill(0, "取消", fg: Pal.subtext,
                         base: .clear, hover: Pal.fill(0.07), border: .clear, action: onCancel)
                    pill(1, "重新加载", fg: Pal.text,
                         base: Pal.fill(0.07), hover: Pal.fill(0.13), border: Pal.fill(0.10), action: onReload)
                    pill(2, "覆盖", fg: Pal.red,
                         base: Pal.red.opacity(0.12), hover: Pal.red.opacity(0.20),
                         border: Pal.red.opacity(0.28), action: onOverwrite)
                }
            }
            .padding(18)
            .frame(width: 384)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 20, y: 7)
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func pill(_ id: Int, _ title: String, fg: Color,
                      base: Color, hover: Color, border: Color,
                      action: @escaping () -> Void) -> some View {
        let isHover = hovered == id
        return Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 6.5)
                .background(isHover ? hover : base, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
    }
}
