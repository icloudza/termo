import SwiftUI

/// 侧栏宽度独立成一个极小的 ObservableObject —— 故意从 [[AppModel]] 拆出来。
///
/// 原因:`AppModel` 被 ContentView / Sidebar / TabBar / Workspace 等几乎所有视图共同
/// 观察。若把 `sidebarWidth` 放在它身上,任何一次宽度变化(尤其拖动分隔条时每帧一次)都会
/// 触发 `objectWillChange`,使所有持有 `@ObservedObject var model` 的视图同帧重算 body
/// —— 标签越多、文件树行越多就越卡。
///
/// 把宽度放进本对象后,只有真正参与缩放的视图(Sidebar 的 frame、SidebarDivider)订阅它,
/// TabBar / Workspace 的 `model` 入参不变 → SwiftUI 跳过它们的 body 重算,拖动只剩侧栏自身
/// 这点开销。
@MainActor
final class LayoutModel: ObservableObject {
    /// 展开时的最小宽度：侧栏内容按这个宽度排版，再窄就被裁掉（按钮、延迟数字切一半），所以不允许停在更窄处。
    static let minExpanded: CGFloat = 200
    private static let widthKey = "sidebarWidth"

    /// 侧栏宽度(像素)。0 视为折叠。
    @Published var sidebarWidth: CGFloat {
        didSet {
            guard sidebarWidth >= Self.minExpanded, sidebarWidth != expandedWidth else { return }
            expandedWidth = sidebarWidth
            UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.widthKey)
        }
    }
    /// 最近一次展开的宽度（持久化）：折叠后再展开、重启后都回到用户拖好的宽度。
    private(set) var expandedWidth: CGFloat

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        // 只有「文件」分区允许拖到 320 以上；启动总在「主机」分区，宽度按 320 封顶。
        let w = saved >= Double(Self.minExpanded) ? min(CGFloat(saved), 320) : 224
        expandedWidth = w
        sidebarWidth = w
    }

    var isCollapsed: Bool { sidebarWidth < 10 }
    func expand() { sidebarWidth = expandedWidth }
    func toggle() { sidebarWidth = isCollapsed ? expandedWidth : 0 }
}
