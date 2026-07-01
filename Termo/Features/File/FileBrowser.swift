import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 单个文件浏览标签的导航状态（每标签一份，AppModel 缓存）。
@MainActor
final class BrowserState: ObservableObject, FileOpsTarget {
    @Published var path: String = ""
    @Published var entries: [RemoteFile] = []
    @Published var phase: LoadPhase = .loading
    @Published var showHidden = false
    @Published var selection: Set<String> = []   // 选中文件路径（多选下载）
    @Published var hoveredPath: String? = nil     // 鼠标悬停的行（由统一交互层上报）
    var marqueeBase: Set<String> = []             // 框选开始前的选择快照（ESC 取消时恢复）

    private let fs: RemoteFS
    private var backStack: [String] = []
    private var loadTask: Task<Void, Never>?
    private var started = false

    init(fs: RemoteFS) { self.fs = fs }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoUp: Bool { path != "/" && !path.isEmpty }

    /// 可见条目（按隐藏文件开关过滤）。
    var visible: [RemoteFile] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    /// 当前选中的条目。
    var selectedFiles: [RemoteFile] { visible.filter { selection.contains($0.path) } }

    private var anchorPath: String?   // 范围选择的锚点

    /// 点击选择：普通=单选；⌘=切换；⇧=从锚点到此的区间选。
    func click(_ p: String, cmd: Bool, shift: Bool) {
        let paths = visible.map(\.path)
        if shift, let anchor = anchorPath,
           let a = paths.firstIndex(of: anchor), let b = paths.firstIndex(of: p) {
            selection = Set(paths[min(a, b)...max(a, b)])   // 锚点保持不变
        } else if cmd {
            if selection.contains(p) { selection.remove(p) } else { selection.insert(p) }
            anchorPath = p
        } else {
            selection = [p]
            anchorPath = p
        }
    }

    /// 首次出现时加载家目录。
    func startIfNeeded() {
        guard !started else { return }
        started = true
        loadTask = Task {
            let home = await fs.home()
            await load(home, pushBack: false)
        }
    }

    func enter(_ file: RemoteFile) {
        guard file.isDir else { return }
        navigate(to: file.path)
    }

    func goUp() {
        guard canGoUp else { return }
        let parent = (path as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/" : parent)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        loadTask?.cancel()
        loadTask = Task { await load(prev, pushBack: false) }
    }

    func reload() {
        loadTask?.cancel()
        let p = path
        loadTask = Task { await load(p, pushBack: false) }
    }

    /// 网络恢复后重连：重置底层 SFTP 连接并重载当前目录；未浏览过则跳过。
    func reconnect() {
        guard !path.isEmpty else { return }
        fs.resetForReconnect()
        reload()
    }

    private func navigate(to newPath: String) {
        loadTask?.cancel()
        let from = path
        loadTask = Task {
            await load(newPath, pushBack: true, from: from)
        }
    }

    private func load(_ newPath: String, pushBack: Bool, from: String? = nil) async {
        phase = .loading
        let result = await fs.list(newPath)
        if Task.isCancelled { return }
        switch result {
        case .success(let files):
            if pushBack, let from, !from.isEmpty { backStack.append(from) }
            path = newPath
            entries = files
            selection = []      // 切目录清空选择
            anchorPath = nil
            phase = .loaded
        case .failure(let e):
            phase = .error(e.message)
        }
    }

    func cancel() { loadTask?.cancel() }

    // MARK: - FileOpsTarget（与侧栏文件树共用同一套右击操作）

    func performDelete(_ file: RemoteFile, handle: CommandHandle?) async -> Result<Void, RemoteFSError> {
        let r = await fs.delete(file.path, isDir: file.isDir, handle: handle)
        if case .success = r { reload() }
        return r
    }

    func performRename(_ file: RemoteFile, newName: String) async -> Result<String, RemoteFSError> {
        let parent = (file.path as NSString).deletingLastPathComponent
        let newPath = (parent == "/" || parent.isEmpty) ? "/" + newName : parent + "/" + newName
        let r = await fs.rename(file.path, to: newPath)
        switch r {
        case .success: reload(); return .success(newPath)
        case .failure(let e): return .failure(e)
        }
    }

    func performChmod(_ file: RemoteFile, mode: String) async -> Result<Void, RemoteFSError> {
        await fs.chmod(file.path, mode: mode)
    }

    func currentPerms(_ file: RemoteFile) async -> Int? {
        if case .success(let v) = await fs.statPerms(file.path) { return v }
        return nil
    }

    func performCreate(_ name: String, isDir: Bool, inDir dir: String) async -> Result<Void, RemoteFSError> {
        let path = (dir == "/" ? "" : dir) + "/" + name
        let r = isDir ? await fs.mkdir(path) : await fs.createFile(path)
        if case .success = r { reload() }
        return r
    }
}

struct FileBrowser: View {
    @ObservedObject var state: BrowserState
    let host: Host
    let model: AppModel
    var onOpenFile: (RemoteFile) -> Void = { _ in }
    @ObservedObject private var theme = ThemeManager.shared
    @State private var dropTarget = false

    private static let dropBlue = Color(hex: 0x1E90FF)
    // 行高与列表顶部内边距：统一交互层据此把鼠标 y 映射到行索引，故必须与渲染一致。
    static let rowHeight: CGFloat = 28
    static let topInset: CGFloat = 4
    /// 已连接（有路径）才允许拖拽上传到当前目录。
    private var canUpload: Bool { !state.path.isEmpty }

    /// 当前目录作为上传目标。
    private var currentDir: RemoteFile {
        let name = state.path == "/" ? "/" : (state.path as NSString).lastPathComponent
        return RemoteFile(name: name, path: state.path, kind: .directory, size: 0, modified: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Pal.fill(0.06))
            columnHeader
            Divider().overlay(Pal.fill(0.06))
            content
        }
        .background(Pal.base)
        .overlay { if dropTarget { dropOverlay } }
        .animation(.easeOut(duration: 0.12), value: dropTarget)
        .onDrop(of: [.fileURL], isTargeted: canUpload ? $dropTarget : nil) { providers in
            guard canUpload else { return false }
            loadURLs(providers) { urls in
                if !urls.isEmpty { model.uploadFiles(urls, toDir: state.path, host: host) }
            }
            return true
        }
        .onAppear { state.startIfNeeded() }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Self.dropBlue.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.dropBlue, lineWidth: 2))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 22, weight: .medium))
                    Text("松开以上传到当前目录").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Self.dropBlue)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Pal.solidMantle.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func loadURLs(_ providers: [NSItemProvider], _ completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            iconButton("chevron.left", enabled: state.canGoBack) { state.goBack() }
            iconButton("chevron.up", enabled: state.canGoUp) { state.goUp() }
            iconButton("arrow.clockwise", enabled: true) { state.reload() }

            Text(state.path.isEmpty ? "…" : state.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if !state.selectedFiles.isEmpty {
                let dlFiles = state.selectedFiles.filter { !$0.isDir }
                if !dlFiles.isEmpty {
                    Button { model.downloadFiles(dlFiles, host: host) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 11))
                            Text("下载 (\(dlFiles.count))").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(String(localized: "下载选中的文件"))
                }
                Button { model.requestBatchDelete(state.selectedFiles, host: host, target: state) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash").font(.system(size: 11))
                        Text("删除 (\(state.selectedFiles.count))").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Pal.red)
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(Pal.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(String(localized: "删除选中的项目"))
            }

            Button { model.beginUpload(into: currentDir, host: host) } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor(!state.path.isEmpty)
            .help(String(localized: "上传文件到当前目录"))
            .disabled(state.path.isEmpty)

            Button { state.showHidden.toggle() } label: {
                Image(systemName: state.showHidden ? "eye" : "eye.slash")
                    .font(.system(size: 12)).foregroundStyle(state.showHidden ? Pal.mauve : Pal.overlay)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(state.showHidden ? String(localized: "隐藏点文件") : String(localized: "显示点文件"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func iconButton(_ symbol: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? Pal.subtext : Pal.overlay.opacity(0.4))
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(enabled)
        .disabled(!enabled)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("名称").frame(maxWidth: .infinity, alignment: .leading)
            Text("大小").frame(width: 90, alignment: .trailing)
            Text("修改时间").frame(width: 150, alignment: .trailing)
        }
        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    // MARK: - 内容

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
                    Button("重试") { state.reload() }.buttonStyle(.plain).pointerCursor().foregroundStyle(Pal.mauve)
                }
                .padding(.horizontal, 40)
            }
        case .loaded:
            // 整张列表的鼠标交互（单/双击、悬停、光标、橡皮筋框选、右键菜单）由统一的 AppKit 交互层接管，
            // 行只负责展示。用 GeometryReader 让内容至少铺满视口，空白区也参与命中。
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.visible) { file in
                            FileRow(file: file,
                                    selected: state.selection.contains(file.path),
                                    hovered: state.hoveredPath == file.path)
                                .frame(height: Self.rowHeight)
                        }
                        if state.visible.isEmpty {
                            Text("空目录").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                                .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                    }
                    .padding(.vertical, Self.topInset)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .overlay(
                        FileListInteraction(
                            rowCount: state.visible.count,
                            rowHeight: Self.rowHeight,
                            topInset: Self.topInset,
                            onPrimaryClick: { i, cmd, shift in handlePrimaryClick(i, cmd: cmd, shift: shift) },
                            onOpen: { i in handleOpen(i) },
                            onHover: { i in
                                state.hoveredPath = i.flatMap { state.visible.indices.contains($0) ? state.visible[$0].path : nil }
                            },
                            onMarquee: { idxs in handleMarquee(idxs) },
                            onMarqueeBegin: { state.marqueeBase = state.selection },
                            onMarqueeCancel: { state.selection = state.marqueeBase },
                            onEscape: { state.selection = [] },
                            makeMenu: { i in makeContextMenu(forIndex: i) }
                        )
                    )
                }
            }
        }
    }

    private func handlePrimaryClick(_ i: Int?, cmd: Bool, shift: Bool) {
        if let i, state.visible.indices.contains(i) {
            state.click(state.visible[i].path, cmd: cmd, shift: shift)
        } else if !cmd, !shift {
            state.selection = []   // 点空白处清空选择
        }
    }

    private func handleOpen(_ i: Int?) {
        guard let i, state.visible.indices.contains(i) else { return }
        let f = state.visible[i]
        if f.isDir { state.enter(f) } else { onOpenFile(f) }
    }

    private func handleMarquee(_ idxs: Set<Int>) {
        state.selection = Set(idxs.compactMap { state.visible.indices.contains($0) ? state.visible[$0].path : nil })
    }

    // MARK: - 右键菜单（AppKit，因统一交互层在前会拦截 SwiftUI 的 contextMenu）

    private func makeContextMenu(forIndex i: Int?) -> NSMenu? {
        let menu = NSMenu()
        if let i, state.visible.indices.contains(i) {
            let file = state.visible[i]
            if !state.selection.contains(file.path) { state.selection = [file.path] }   // 右键未选中项 → 先选中它
            if state.selection.count > 1, state.selection.contains(file.path) {
                let sel = state.selectedFiles
                let dl = sel.filter { !$0.isDir }
                if !dl.isEmpty {
                    menu.addItem(ClosureMenuItem(title: String(localized: "下载选中 (\(dl.count))"), systemImage: "square.and.arrow.down") {
                        model.downloadFiles(dl, host: host)
                    })
                    menu.addItem(.separator())
                }
                menu.addItem(ClosureMenuItem(title: String(localized: "删除选中 (\(sel.count))"), systemImage: "trash") {
                    model.requestBatchDelete(sel, host: host, target: state)
                })
            } else {
                addSingleFileItems(to: menu, file: file)
            }
        } else {
            addBlankItems(to: menu)
        }
        return menu
    }

    private func addSingleFileItems(to menu: NSMenu, file: RemoteFile) {
        if file.isDir {
            menu.addItem(ClosureMenuItem(title: String(localized: "上传文件…"), systemImage: "square.and.arrow.up") {
                model.beginUpload(into: file, host: host)
            })
            menu.addItem(ClosureMenuItem(title: String(localized: "新建文件"), systemImage: "doc.badge.plus") {
                model.fileMenuRequestCreate(isDir: false, inDir: file.path, host: host, target: state)
            })
            menu.addItem(ClosureMenuItem(title: String(localized: "新建文件夹"), systemImage: "folder.badge.plus") {
                model.fileMenuRequestCreate(isDir: true, inDir: file.path, host: host, target: state)
            })
            menu.addItem(.separator())
        } else {
            menu.addItem(ClosureMenuItem(title: String(localized: "下载"), systemImage: "square.and.arrow.down") {
                model.downloadFiles([file], host: host)
            })
            if ArchiveKind.detect(file.name) != nil {
                menu.addItem(ClosureMenuItem(title: String(localized: "解压"), systemImage: "doc.zipper") {
                    model.requestExtract(file, host: host)
                })
            }
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: String(localized: "刷新"), systemImage: "arrow.clockwise") { state.reload() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "重命名"), systemImage: "pencil") {
            model.fileMenuRequestRename(file, host: host, target: state)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "权限"), systemImage: "lock") {
            model.fileMenuRequestChmod(file, host: host, target: state)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "删除"), systemImage: "trash") {
            model.fileMenuRequestDelete(file, host: host, target: state)
        })
    }

    private func addBlankItems(to menu: NSMenu) {
        menu.addItem(ClosureMenuItem(title: String(localized: "上传文件到此处"), systemImage: "square.and.arrow.up") {
            model.beginUpload(into: currentDir, host: host)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "新建文件"), systemImage: "doc.badge.plus") {
            model.fileMenuRequestCreate(isDir: false, inDir: state.path, host: host, target: state)
        })
        menu.addItem(ClosureMenuItem(title: String(localized: "新建文件夹"), systemImage: "folder.badge.plus") {
            model.fileMenuRequestCreate(isDir: true, inDir: state.path, host: host, target: state)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: String(localized: "刷新"), systemImage: "arrow.clockwise") { state.reload() })
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileRow: View {
    let file: RemoteFile
    let selected: Bool
    let hovered: Bool
    // 观察主题：切换深浅色时强制重算 body，否则 Pal 配色不刷新（旧色残留，hover 才意外恢复）。
    @ObservedObject private var theme = ThemeManager.shared

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                FileTypeIcon(file: file, size: 13)
                    .frame(width: 18)
                Text(file.name).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.isDir ? "—" : humanSize(file.size))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                .frame(width: 90, alignment: .trailing)
            Text(file.modified.map { Self.dateFmt.string(from: $0) } ?? "—")
                .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
        .background(selected ? Pal.mauve.opacity(0.16) : (hovered ? Pal.fill(0.05) : Color.clear))
        // 仅选中行上报自身全局矩形（按远端路径索引），作为「下载飞入」动画的起点；非选中行无此开销。
        .background {
            if selected {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { AppModel.shared.fileRowGlobalFrames[file.path] = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { AppModel.shared.fileRowGlobalFrames[file.path] = $0 }
                        .onDisappear { AppModel.shared.fileRowGlobalFrames[file.path] = nil }
                }
            }
        }
        // 纯展示：所有鼠标交互由上层统一的 FileListInteraction 处理。
    }
}

/// 闭包式菜单项：让 AppKit NSMenu 用闭包写动作（自身做 target，避免散落的 @objc 选择器）。
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        if let systemImage {
            self.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// 文件列表统一交互层：覆盖整张列表，在单一坐标系内处理 单击/双击/悬停/光标/橡皮筋框选/右键菜单。
/// 行高固定，按 y 映射行索引；橡皮筋拖拽即时框选，不与 ScrollView 的滚动手势冲突（点击拖拽 ≠ 滚轮/触控板滚动）。
struct FileListInteraction: NSViewRepresentable {
    var rowCount: Int
    var rowHeight: CGFloat
    var topInset: CGFloat
    var onPrimaryClick: (_ index: Int?, _ cmd: Bool, _ shift: Bool) -> Void
    var onOpen: (_ index: Int?) -> Void
    var onHover: (_ index: Int?) -> Void
    var onMarquee: (_ indices: Set<Int>) -> Void
    var onMarqueeBegin: () -> Void
    var onMarqueeCancel: () -> Void
    var onEscape: () -> Void
    var makeMenu: (_ index: Int?) -> NSMenu?

    func makeNSView(context: Context) -> InteractionView { InteractionView() }

    func updateNSView(_ v: InteractionView, context: Context) {
        v.rowCount = rowCount
        v.rowHeight = rowHeight
        v.topInset = topInset
        v.onPrimaryClick = onPrimaryClick
        v.onOpen = onOpen
        v.onHover = onHover
        v.onMarquee = onMarquee
        v.onMarqueeBegin = onMarqueeBegin
        v.onMarqueeCancel = onMarqueeCancel
        v.onEscape = onEscape
        v.makeMenu = makeMenu
    }

    final class InteractionView: NSView {
        var rowCount = 0
        var rowHeight: CGFloat = 28
        var topInset: CGFloat = 4
        var onPrimaryClick: (Int?, Bool, Bool) -> Void = { _, _, _ in }
        var onOpen: (Int?) -> Void = { _ in }
        var onHover: (Int?) -> Void = { _ in }
        var onMarquee: (Set<Int>) -> Void = { _ in }
        var onMarqueeBegin: () -> Void = {}
        var onMarqueeCancel: () -> Void = {}
        var onEscape: () -> Void = {}
        var makeMenu: (Int?) -> NSMenu? = { _ in nil }

        private var dragStart: NSPoint?
        private var marqueeActive = false
        private var marqueeAborted = false
        private var marqueeRect: NSRect?

        override var isFlipped: Bool { true }   // 原点左上、y 向下，与行的自上而下顺序一致
        override var acceptsFirstResponder: Bool { true }   // 需成为第一响应者以接收 ESC

        // 在翻转坐标系里直接用 draw 画橡皮筋框（CALayer 子层不随视图翻转，几何会镜像，故用 draw）。
        override func draw(_ dirtyRect: NSRect) {
            guard let r = marqueeRect else { return }
            let accent = NSColor.selectedContentBackgroundColor
            accent.withAlphaComponent(0.18).setFill()
            accent.setStroke()
            let path = NSBezierPath(rect: r)
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }

        /// 命中点落在第几行（nil=空白区）。
        private func index(at p: NSPoint) -> Int? {
            let y = p.y - topInset
            guard y >= 0 else { return nil }
            let i = Int(floor(y / rowHeight))
            return (0..<rowCount).contains(i) ? i : nil
        }

        private func indices(in rect: NSRect) -> Set<Int> {
            guard rowCount > 0, rowHeight > 0 else { return [] }
            let lo = Int(floor((rect.minY - topInset) / rowHeight))
            let hi = Int(floor((rect.maxY - topInset) / rowHeight))
            guard hi >= 0, lo < rowCount else { return [] }   // 矩形与内容无纵向交叠
            var out = Set<Int>()
            for i in max(0, lo)...min(rowCount - 1, hi) { out.insert(i) }
            return out
        }

        // 让窗口投递 mouseMoved，确保悬停高亮生效（tracking area 的 .mouseMoved 之外再加一道保险）。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        // 悬停 / 光标
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                owner: self, userInfo: nil))
        }
        override func mouseMoved(with event: NSEvent) {
            onHover(index(at: convert(event.locationInWindow, from: nil)))
        }
        override func mouseExited(with event: NSEvent) { onHover(nil) }
        override func cursorUpdate(with event: NSEvent) {
            if index(at: convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)   // 取得键盘焦点以便接收 ESC
            let p = convert(event.locationInWindow, from: nil)
            if event.clickCount >= 2 {
                onOpen(index(at: p)); dragStart = nil; return
            }
            dragStart = p
            marqueeActive = false
            marqueeAborted = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart, !marqueeAborted else { return }
            let p = convert(event.locationInWindow, from: nil)
            if !marqueeActive, hypot(p.x - start.x, p.y - start.y) > 4 {
                marqueeActive = true
                onMarqueeBegin()   // 快照框选前的选择，供 ESC 取消时恢复
            }
            guard marqueeActive else { return }
            let rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(p.x - start.x), height: abs(p.y - start.y))
            marqueeRect = rect
            needsDisplay = true
            onMarquee(indices(in: rect))
        }

        override func mouseUp(with event: NSEvent) {
            defer { dragStart = nil; marqueeActive = false; marqueeAborted = false }
            if marqueeAborted { marqueeRect = nil; needsDisplay = true; return }   // ESC 已取消
            if marqueeActive {
                marqueeRect = nil
                needsDisplay = true
                return
            }
            let p = convert(event.locationInWindow, from: nil)
            onPrimaryClick(index(at: p), event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift))
        }

        // ESC：框选拖拽中 → 撤销本次框选并恢复原选择；否则（已选中状态）→ 清空选择。
        override func cancelOperation(_ sender: Any?) {
            if marqueeActive, !marqueeAborted {
                marqueeAborted = true
                marqueeRect = nil
                needsDisplay = true
                onMarqueeCancel()
            } else if dragStart == nil {
                onEscape()
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            makeMenu(index(at: convert(event.locationInWindow, from: nil)))
        }
    }
}
