import SwiftUI

/// 单个文件浏览标签的导航状态（每标签一份，AppModel 缓存）。
@MainActor
final class BrowserState: ObservableObject, FileOpsTarget {
    @Published var path: String = ""
    @Published var entries: [RemoteFile] = []
    @Published var phase: LoadPhase = .loading
    @Published var showHidden = false

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
            phase = .loaded
        case .failure(let e):
            phase = .error(e.message)
        }
    }

    func cancel() { loadTask?.cancel() }

    // MARK: - FileOpsTarget（与侧栏文件树共用同一套右击操作）

    func performDelete(_ file: RemoteFile) async -> Result<Void, RemoteFSError> {
        let r = await fs.delete(file.path, isDir: file.isDir)
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

            Button { model.beginUpload(into: currentDir, host: host) } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("上传文件到当前目录")
            .disabled(state.path.isEmpty)

            Button { state.showHidden.toggle() } label: {
                Image(systemName: state.showHidden ? "eye" : "eye.slash")
                    .font(.system(size: 12)).foregroundStyle(state.showHidden ? Pal.mauve : Pal.overlay)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    Button("重试") { state.reload() }.buttonStyle(.plain).foregroundStyle(Pal.mauve)
                }
                .padding(.horizontal, 40)
            }
        case .loaded:
            // 用 GeometryReader 把内容撑满视口，使「行以下的空白区」也算内容、可右击空白菜单。
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.visible) { file in
                            FileRow(file: file) {
                                if file.isDir { state.enter(file) } else { onOpenFile(file) }
                            }
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
        Divider()
        Button { state.reload() } label: { Label("刷新", systemImage: "arrow.clockwise") }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileRow: View {
    let file: RemoteFile
    let onOpen: () -> Void
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
        .background(hover ? Pal.fill(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onOpen() }
    }
}
