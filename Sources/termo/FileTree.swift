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
}

/// 侧栏远程文件目录树（VS Code 资源管理器风格，随终端 cwd 定位）。
struct SidebarFileTree: View {
    @ObservedObject var state: FileTreeState
    var onOpenFile: (RemoteFile) -> Void
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
                                        onTap: { state.toggle(item.node) },
                                        onOpenFile: onOpenFile)
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
    let onTap: () -> Void
    let onOpenFile: (RemoteFile) -> Void
    @State private var hover = false

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
    }
}
