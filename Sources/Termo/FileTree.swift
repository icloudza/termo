import SwiftUI

/// 目录树节点（纯数据；不再是 ObservableObject——避免上千节点各自观察的开销）。
final class FileTreeNode {
    let file: RemoteFile
    var children: [FileTreeNode]? = nil   // nil = 尚未加载
    var isExpanded = false
    var isLoading = false
    init(file: RemoteFile) { self.file = file }
}

/// 拍平后的一行（节点 + 缩进深度）。LazyVStack 只渲染可见行。
struct FlatNode: Identifiable {
    let node: FileTreeNode
    let depth: Int
    var id: String { node.file.path }
}

/// 某主机某标签的文件树状态。核心：把展开的树拍平成 `flat`，
/// LazyVStack 据此只渲染屏幕可见行 —— 树再大也不卡。
@MainActor
final class FileTreeState: ObservableObject {
    private let fs: RemoteFS
    private var roots: [FileTreeNode] = []
    @Published var flat: [FlatNode] = []
    @Published var phase: LoadPhase = .loading
    @Published var selectedPath: String? = nil
    private var started = false
    private var revealTarget: String?

    init(fs: RemoteFS, revealOnLoad: String? = nil) {
        self.fs = fs
        self.revealTarget = revealOnLoad
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task {
            let r = await fs.list("/")
            switch r {
            case .success(let files):
                roots = files.map { FileTreeNode(file: $0) }
                phase = .loaded
                rebuild()
                // 加载完成后再取最新的定位目标：预热期间若已请求 reveal 某文件，这里能拿到
                let target: String
                if let t = revealTarget { target = t } else { target = await fs.home() }
                await revealPath(target)
            case .failure(let e):
                phase = .error(e.message)
            }
        }
    }

    /// 展开/收起一个目录节点。
    func toggle(_ node: FileTreeNode) {
        guard node.file.isDir else { return }
        node.isExpanded.toggle()
        if node.isExpanded, node.children == nil {
            node.isLoading = true
            rebuild()
            Task {
                let ok = await load(node)
                // 加载失败（超时/连接抖动）则收起，避免「展开却空」的假象；下次点击会重新拉取
                if !ok { node.isExpanded = false }
                rebuild()
            }
        } else {
            rebuild()
        }
    }

    /// 加载某目录的子节点。返回是否成功——失败**不缓存**（children 保持 nil），
    /// 否则一次瞬时失败会把目录永久显示成空、再展开也不重拉。
    @discardableResult
    private func load(_ node: FileTreeNode) async -> Bool {
        let r = await fs.list(node.file.path)
        node.isLoading = false
        switch r {
        case .success(let files):
            node.children = files.map { FileTreeNode(file: $0) }
            return true
        case .failure:
            node.children = nil
            return false
        }
    }

    /// 终端 cd 后定位到某路径（展开各级祖先并选中）。
    func reveal(_ path: String) {
        revealTarget = path
        guard phase == .loaded else { return }
        Task { await revealPath(path) }
    }

    private func revealPath(_ path: String) async {
        let comps = path.split(separator: "/").map(String.init)
        var level = roots
        var target: FileTreeNode?
        for comp in comps {
            guard let node = level.first(where: { $0.file.name == comp }) else { break }
            target = node
            guard node.file.isDir else { break }
            // 加载失败则停在这一级，不展开、不缓存空（保持 children == nil 允许重试）
            if node.children == nil { guard await load(node) else { break } }
            node.isExpanded = true
            level = node.children ?? []
        }
        selectedPath = target?.file.path
        rebuild()
    }

    /// 把当前展开的树拍平成一维可见行数组。
    private func rebuild() {
        var out: [FlatNode] = []
        func walk(_ nodes: [FileTreeNode], _ depth: Int) {
            for n in nodes {
                out.append(FlatNode(node: n, depth: depth))
                if n.isExpanded, let ch = n.children { walk(ch, depth + 1) }
            }
        }
        walk(roots, 0)
        flat = out
    }

    func reload() {
        started = false
        roots = []
        flat = []
        phase = .loading
        selectedPath = nil
        startIfNeeded()
    }

    // MARK: - 文件管理（右键菜单用）

    enum RefreshOutcome { case ok, gone, failed(String) }

    static func parentPath(_ p: String) -> String {
        guard let slash = p.lastIndex(of: "/"), slash != p.startIndex else { return "/" }
        return String(p[p.startIndex..<slash])
    }

    /// 按路径在树中查找节点（深度优先）。
    func node(at path: String) -> FileTreeNode? {
        func walk(_ nodes: [FileTreeNode]) -> FileTreeNode? {
            for n in nodes {
                if n.file.path == path { return n }
                if let ch = n.children, let hit = walk(ch) { return hit }
            }
            return nil
        }
        return walk(roots)
    }

    /// 重新拉取某目录（保持展开）。失败时用 exists 区分「远端已删除」与瞬时失败。
    @discardableResult
    func refreshDir(_ path: String) async -> RefreshOutcome {
        if path == "/" || path.isEmpty {
            let r = await fs.list("/")
            if case .success(let files) = r { roots = files.map { FileTreeNode(file: $0) }; rebuild(); return .ok }
            return await fs.exists("/") ? .failed("无法刷新") : .gone
        }
        guard let node = node(at: path), node.file.isDir else { return .failed("不是目录") }
        let r = await fs.list(path)
        switch r {
        case .success(let files):
            node.children = files.map { FileTreeNode(file: $0) }
            node.isExpanded = true
            rebuild()
            return .ok
        case .failure(let e):
            return await fs.exists(path) ? .failed(e.message) : .gone
        }
    }

    /// 刷新某文件所在的目录。
    @discardableResult
    func refreshParent(of filePath: String) async -> RefreshOutcome {
        await refreshDir(Self.parentPath(filePath))
    }

    /// 从树中移除某节点（删除后 / 远端已不存在时）并选中其上级。
    func removeAndSelectParent(_ path: String) {
        let parent = Self.parentPath(path)
        func remove(_ nodes: inout [FileTreeNode]) -> Bool {
            if let idx = nodes.firstIndex(where: { $0.file.path == path }) { nodes.remove(at: idx); return true }
            for n in nodes where n.children != nil {
                if remove(&n.children!) { return true }
            }
            return false
        }
        _ = remove(&roots)
        selectedPath = (parent == "/") ? nil : parent
        rebuild()
    }

    /// 删除：远端删除成功后从树移除并选中上级。
    func performDelete(_ file: RemoteFile) async -> Result<Void, RemoteFSError> {
        let r = await fs.delete(file.path, isDir: file.isDir)
        if case .success = r { removeAndSelectParent(file.path) }
        return r
    }

    /// 重命名（同目录改名）：成功后刷新所在目录。返回新路径供上层更新已打开编辑器。
    func performRename(_ file: RemoteFile, newName: String) async -> Result<String, RemoteFSError> {
        let newPath = Self.parentPath(file.path) == "/" ? "/" + newName : Self.parentPath(file.path) + "/" + newName
        let r = await fs.rename(file.path, to: newPath)
        switch r {
        case .success:
            await refreshParent(of: file.path)
            selectedPath = newPath
            rebuild()
            return .success(newPath)
        case .failure(let e):
            return .failure(e)
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

/// 侧栏远程文件目录树（VS Code 资源管理器风格，随终端 cwd 定位）。
struct SidebarFileTree: View {
    @ObservedObject var state: FileTreeState
    let host: Host
    let model: AppModel
    // 注意：不要在此存任何闭包属性。闭包每帧新建会让 SwiftUI 认为输入变化 → 拖动侧栏宽度时
    // 重算 ForEach(数千行) → 卡顿。打开文件直接用内部的 model.openFile，保持存储属性可比较、可跳过重算。
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Group {
            switch state.phase {
            case .loading:
                centered { ProgressView().controlSize(.small) }
            case .error(let msg):
                centered {
                    VStack(spacing: 8) {
                        Text(msg).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .multilineTextAlignment(.center).lineLimit(4)
                        Button("重试") { state.reload() }.buttonStyle(.plain).foregroundStyle(Pal.mauve)
                    }
                    .padding(.horizontal, 16)
                }
            case .loaded:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(state.flat) { item in
                                FlatRow(item: item,
                                        selected: state.selectedPath,
                                        host: host, model: model, tree: state,
                                        onTap: { state.toggle(item.node) },
                                        onOpenFile: { model.openFile($0, host: host) })
                                .id(item.node.file.path)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: state.selectedPath) { sel in
                        guard let sel else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(sel, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { state.startIfNeeded() }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack { Spacer(); c(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 单行（非递归、纯值渲染）。
private struct FlatRow: View {
    let item: FlatNode
    let selected: String?
    let host: Host
    let model: AppModel
    let tree: FileTreeState
    let onTap: () -> Void
    let onOpenFile: (RemoteFile) -> Void
    @State private var hover = false

    /// 估算名字是否可能被截断 → 截断才挂 tooltip。
    /// 廉价估算:仅按字符数 + 缩进深度判断,不做 NSString 文本测量、也不读侧栏宽度
    /// （宽度已移出 AppModel;逐行测量在拖动/滚动时是明显的 CPU 浪费）。阈值按默认侧栏宽
    /// （≈224px,约可容 30 个字符）取定;侧栏更窄时缩进会进一步压低可用字符数,故计入 depth。
    private var nameTruncated: Bool {
        item.node.file.name.count + item.depth * 2 > 30
    }

    var body: some View {
        let node = item.node
        Button {
            if node.file.isDir { onTap() } else { onOpenFile(node.file) }
        } label: {
            HStack(spacing: 4) {
                if node.file.isDir {
                    Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 12)
                } else {
                    Spacer().frame(width: 12)
                }
                let ic = FileIcon.info(for: node.file)
                Image(systemName: ic.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(ic.color)
                    .frame(width: 16)
                Text(node.file.name)
                    .font(.system(size: 12)).foregroundStyle(Pal.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if node.isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(item.depth) * 12 + 10)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == node.file.path ? Pal.mauve.opacity(0.18) : (hover ? Pal.fill(0.05) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button { model.fileMenuRefresh(node.file, host: host, tree: tree) } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Divider()
            Button { model.fileMenuRequestRename(node.file, host: host, tree: tree) } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { model.fileMenuRequestChmod(node.file, host: host, tree: tree) } label: {
                Label("权限", systemImage: "lock")
            }
            Divider()
            Button(role: .destructive) { model.fileMenuRequestDelete(node.file, host: host, tree: tree) } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .tooltip(node.file.name, when: nameTruncated)
    }
}
