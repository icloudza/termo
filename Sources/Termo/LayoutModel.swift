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
    /// 侧栏宽度(像素)。0 视为折叠。
    @Published var sidebarWidth: CGFloat = 224
}
