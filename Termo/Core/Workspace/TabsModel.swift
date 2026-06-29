import Foundation

/// 标签页状态（打开的标签 + 当前活动标签），从 `AppModel` 拆出独立成 ObservableObject。
///
/// 目的：让 `TabBar`/`Workspace` 这类重控件只在标签变化时重算，不再被 AppModel 上
/// hosts/query/弹窗等无关 @Published 牵动重渲染（同 [[LayoutModel]] 的解耦思路）。
///
/// AppModel 通过转发计算属性 `tabs`/`activeTabId` 读写本模型，内部逻辑零改动；
/// 仅视图层从观察 AppModel 改为观察 TabsModel。
@MainActor
final class TabsModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: Int? = nil
}
