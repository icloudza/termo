import AppKit
import SwiftUI

/// 单个文件浏览标签的导航状态（每标签一份，AppModel 缓存）。
@MainActor
final class BrowserState: ObservableObject, FileOpsTarget {
    @Published var path: String = ""
    @Published var entries: [RemoteFile] = []
    @Published var phase: LoadPhase = .loading
    @Published var showHidden = false
    @Published var selection: Set<String> = []   // 选中文件路径（多选下载）

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
        .onAppear { state.startIfNeeded() }
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
                Button { model.downloadFiles(state.selectedFiles, host: host) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 11))
                        Text("下载 (\(state.selectedFiles.count))").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Pal.mauve)
                    .padding(.horizontal, 9).frame(height: 26)
                    .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("下载选中的文件")
            }

            Button { model.beginUpload(into: currentDir, host: host) } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor(!state.path.isEmpty)
            .help("上传文件到当前目录")
            .disabled(state.path.isEmpty)

            Button { state.showHidden.toggle() } label: {
                Image(systemName: state.showHidden ? "eye" : "eye.slash")
                    .font(.system(size: 12)).foregroundStyle(state.showHidden ? Pal.mauve : Pal.overlay)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(state.showHidden ? "隐藏点文件" : "显示点文件")
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
            // 用 GeometryReader 把内容撑满视口，使「行以下的空白区」也算内容、可右击空白菜单。
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.visible) { file in
                            FileRow(file: file, selected: state.selection.contains(file.path),
                                    onOpen: { if file.isDir { state.enter(file) } else { onOpenFile(file) } },
                                    onClick: { cmd, shift in state.click(file.path, cmd: cmd, shift: shift) })
                                .fileOpsMenu(file: file, host: host, model: model,
                                             target: state, onRefresh: { state.reload() })
                        }
                        if state.visible.isEmpty {
                            Text("空目录").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                                .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())                  // 空白区参与命中
                    .contextMenu { blankAreaMenu }              // 右击空白：上传到当前目录 / 刷新（行自身菜单仍优先）
                }
            }
        }
    }

    /// 右击文件列表空白处的菜单：上传到当前目录、刷新。
    @ViewBuilder
    private var blankAreaMenu: some View {
        Button { model.beginUpload(into: currentDir, host: host) } label: {
            Label("上传文件到此处", systemImage: "square.and.arrow.up")
        }
        Button { model.fileMenuRequestCreate(isDir: false, inDir: state.path, host: host, target: state) } label: {
            Label("新建文件", systemImage: "doc.badge.plus")
        }
        Button { model.fileMenuRequestCreate(isDir: true, inDir: state.path, host: host, target: state) } label: {
            Label("新建文件夹", systemImage: "folder.badge.plus")
        }
        Divider()
        Button { state.reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileRow: View {
    let file: RemoteFile
    let selected: Bool
    let onOpen: () -> Void
    let onClick: (_ cmd: Bool, _ shift: Bool) -> Void
    @State private var hover = false

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                let ic = FileIcon.info(for: file)
                Image(systemName: ic.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(ic.color)
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
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(selected ? Pal.mauve.opacity(0.16) : (hover ? Pal.fill(0.05) : Color.clear))
        .contentShape(Rectangle())
        // 用 AppKit 接管：mouseDown 按下即响应（clickCount 分单/双击、modifierFlags 读 ⌘/⇧）；
        // hover 也由 AppKit 的 mouseEntered/Exited 驱动——上层 NSView 会拦截 SwiftUI 的 .onHover，故不在此用。
        .overlay(RowClicks(onSelect: onClick, onOpen: onOpen, onHover: { hover = $0 }))
    }
}

/// 行点击捕获：左键单击→选择（带 ⌘/⇧），双击→打开；右键交还给下层 SwiftUI 的 contextMenu。
/// 同时承担 hover 上报：此 NSView 盖在行上会拦截 SwiftUI 的 .onHover，故 hover 由它的 mouseEntered/Exited 驱动。
private struct RowClicks: NSViewRepresentable {
    let onSelect: (_ cmd: Bool, _ shift: Bool) -> Void
    let onOpen: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        ClickView(onSelect: onSelect, onOpen: onOpen, onHover: onHover)
    }
    func updateNSView(_ v: NSView, context: Context) {
        guard let cv = v as? ClickView else { return }
        cv.onSelect = onSelect; cv.onOpen = onOpen; cv.onHover = onHover
    }

    final class ClickView: NSView {
        var onSelect: (Bool, Bool) -> Void
        var onOpen: () -> Void
        var onHover: (Bool) -> Void
        init(onSelect: @escaping (Bool, Bool) -> Void, onOpen: @escaping () -> Void,
             onHover: @escaping (Bool) -> Void) {
            self.onSelect = onSelect; self.onOpen = onOpen; self.onHover = onHover
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        // 光标与 hover 都用 AppKit 原生方式：跟随可见区的 tracking area，cursorUpdate 显示手型、
        // mouseEntered/Exited 上报悬浮态，在 ScrollView 内也稳定。
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
                owner: self, userInfo: nil))
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onOpen()
            } else {
                let m = event.modifierFlags
                onSelect(m.contains(.command), m.contains(.shift))
            }
        }
        // 右键不接管：把菜单请求交还给下层 SwiftUI 视图（.fileOpsMenu）。
        override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }
    }
}
