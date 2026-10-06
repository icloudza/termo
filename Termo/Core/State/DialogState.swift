import SwiftUI

/// 弹窗、待确认、连接中等界面临时状态。从 [[AppModel]] 拆出：AppModel 被侧栏、活动栏、概览等大视图订阅，
/// 这些状态若留在里面，每开关一次弹窗都会让它们整体重算。这里只有弹窗层订阅。
/// AppModel 保留同名转发属性，业务代码照旧通过 model.xxx 读写。
@MainActor
final class DialogState: ObservableObject {
    @Published var showSettings: Bool = false
    @Published var showAddHost: Bool = false
    @Published var editingHost: Host? = nil   // 非 nil 时以编辑模式打开主机表单
    @Published var showAddRDPHost: Bool = false
    @Published var editingRDPHost: Host? = nil   // 非 nil 时以编辑模式打开 RDP 主机表单
    @Published var showGenerateKey: Bool = false   // 显示「生成密钥」弹窗
    @Published var detailKey: SSHKey? = nil   // 非 nil 显示密钥详情弹窗
    @Published var keyOpError: String? = nil   // 密钥操作错误提示（生成/导入失败）
    @Published var showCreateSnippet: Bool = false   // 显示「新建片段」弹窗
    @Published var editingSnippet: Snippet? = nil   // 非 nil 显示片段编辑/详情弹窗
    @Published var pendingSnippetRun: SnippetRunRequest? = nil   // 非 nil 显示变量填值弹窗
    @Published var pendingSnippetAction: Snippet? = nil   // 非 nil 显示「插入/运行」选择弹窗
    @Published var snippetNotice: String? = nil   // 片段操作提示（如无可用终端）
    @Published var pendingAskAuth: Host? = nil   // 「每次询问」主机的密码弹窗（连接前）
    @Published var pendingHostKey: PendingHostKey? = nil   // 首次连接待验证的主机指纹
    @Published var connectingHost: Host? = nil   // 正在连接的主机（展示连接进度弹窗）
    @Published var connectingRDP: RDPSession? = nil   // 连接中的 RDP 会话：标签未开，弹窗覆盖当前视图，连接成功才开标签
    @Published var pendingRDPOpen: RDPSession? = nil   // 连接成功、等待用户选择打开方式（内嵌/新窗口）的会话
    @Published var pendingFileDelete: FileOpContext? = nil
    @Published var pendingFileRename: FileOpContext? = nil
    @Published var pendingFileChmod: ChmodContext? = nil
    @Published var pendingFileCreate: CreateContext? = nil   // 新建文件/文件夹的名称输入弹窗
    @Published var pendingFileRefresh: RefreshConflictContext? = nil
    @Published var pendingFileInfo: FileInfoContext? = nil
    @Published var focusedTransferId: UUID? = nil
    @Published var flyTransfer: FlyEvent? = nil
    @Published var showExtractDialog: Bool = false   // 解压弹窗是否展开；隐藏后任务仍在后台跑，齿轮旁显示迷你状态
    @Published var fileDeleteBusy: Bool = false   // 删除进行中：弹窗保留 + 删除键旁转圈，可中途取消
    @Published var pendingBatchDelete: BatchDeleteContext? = nil   // 批量删除确认弹窗
    @Published var batchDeleteBusy: Bool = false   // 批量删除进行中：弹窗保留 + 转圈
    @Published var pendingHostDelete: Host? = nil   // 删除主机确认弹窗
    @Published var pendingKeyDelete: SSHKey? = nil   // 删除密钥确认弹窗
    @Published var pendingSnippetDelete: Snippet? = nil   // 删除片段确认弹窗
    @Published var forwardPanelHost: Host? = nil
    @Published var pendingQuitConfirm: Bool = false
    @Published var pendingQuitForce: Bool = false
    @Published var testConnectionDraft: HostDraft? = nil
    @Published var showPrivacyPolicy: Bool = false
    @Published var pendingCloseTabId: Int? = nil
    @Published var pendingTabRename: TabRenameContext? = nil   // 重命名标签输入弹窗
    @Published var pendingMultiClose: MultiCloseContext? = nil   // 批量关闭聚合确认弹窗

    /// 主窗口上是否有任何弹窗：有弹窗时键盘不能留在下层终端/编辑器里，标签类快捷键也不作用于下层。
    var isModalPresented: Bool {
        showSettings || showAddHost || editingHost != nil || showAddRDPHost || editingRDPHost != nil
            || forwardPanelHost != nil || showGenerateKey || detailKey != nil || showCreateSnippet
            || editingSnippet != nil || testConnectionDraft != nil || showPrivacyPolicy
            || keyOpError != nil || snippetNotice != nil
            || pendingCloseTabId != nil || pendingMultiClose != nil || pendingTabRename != nil
            || connectingHost != nil || pendingHostKey != nil || pendingAskAuth != nil
            || connectingRDP != nil || pendingRDPOpen != nil
            || pendingSnippetAction != nil || pendingSnippetRun != nil
            || pendingFileDelete != nil || pendingFileRename != nil || pendingFileChmod != nil
            || pendingFileCreate != nil || pendingFileRefresh != nil || pendingFileInfo != nil
            || pendingBatchDelete != nil || pendingHostDelete != nil
            || pendingKeyDelete != nil || pendingSnippetDelete != nil
            || focusedTransferId != nil || showExtractDialog
            || pendingQuitConfirm
    }
}

/// 侧栏搜索词与脱敏开关。搜索框每敲一个字都会改 query：留在 AppModel 里会让概览页（含监控面板）、
/// 活动栏、各弹窗层逐键重算。只有侧栏各面板与概览（脱敏）订阅这里。AppModel 保留同名转发属性。
@MainActor
final class SidebarState: ObservableObject {
    @Published var query: String = ""
    // 脱敏显示:开启后隐藏列表/概览里的 IP 与主机名(搜索框旁的眼睛按钮切换)。会话级,不持久化。
    @Published var privacyMode: Bool = false
}
