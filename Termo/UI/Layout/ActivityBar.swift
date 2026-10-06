import AppKit
import SwiftUI

struct ActivityBar: View {
    @ObservedObject var model: AppModel
    // 非 @ObservedObject:本视图只在点击闭包里读写宽度,body 不依赖它。
    // 若用 @ObservedObject,即便 body 不读宽度也会订阅其变化、拖动时被白白重算。
    let layout: LayoutModel
    @ObservedObject private var dialogs = AppModel.shared.dialogs   // 设置按钮的选中态
    @ObservedObject private var theme = ThemeManager.shared
    @State private var isFullScreen = false

    private let items: [(String, Section)] = [
        ("server.rack", .hosts),
        ("folder", .files),
        ("key", .sshKeys),
        ("display", .rdp),
        ("chevron.left.forwardslash.chevron.right", .snippets),
    ]

    private func title(_ section: Section) -> String {
        switch section {
        case .hosts: return String(localized: "主机")
        case .files: return String(localized: "文件")
        case .sshKeys: return String(localized: "密钥")
        case .rdp: return String(localized: "远程桌面")
        case .snippets: return String(localized: "代码片段")
        case .settings: return String(localized: "设置")
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(items, id: \.1) { symbol, section in
                item(symbol, section)
            }
            Spacer()
            BackgroundCenterButton(model: model)
                // 任一后台传输需同名确认时，守卫自动展开该任务弹窗，避免静默卡住（原迷你环的职责，已并入中控）。
                // 以 background 挂载：零尺寸、不参与 VStack 间距，避免多出一段空隙。
                .background {
                    ForEach(model.transfers, id: \.id) { task in
                        UploadAskWatcher(task: task) { model.focusedTransferId = task.id }
                    }
                }
            settingsButton
        }
        .padding(.top, isFullScreen ? 12 : 52)
        .padding(.bottom, 12)
        .frame(width: 76)
        .frame(maxHeight: .infinity)
        .background(Pal.crust)
        // 全屏通知是全局的：RDP「新窗口」默认全屏，不能把它当成主窗口全屏（否则活动栏顶到红绿灯下）。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            if Self.isMainWindow(note) { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            if Self.isMainWindow(note) { isFullScreen = false }
        }
    }

    private static func isMainWindow(_ note: Notification) -> Bool {
        guard let w = note.object as? NSWindow else { return false }
        return !(w.windowController is RDPWindowController)
    }

    private var settingsButton: some View {
        ActivityBarButton(symbol: "gearshape", selected: dialogs.showSettings) {
            model.showSettings = true
        }
        .tooltip(String(localized: "设置（⌘,）"))
    }

    @ViewBuilder
    private func item(_ symbol: String, _ section: Section) -> some View {
        ActivityBarButton(symbol: symbol, selected: model.section == section) {
            // 瞬间开合(不加动画):宽度滑动动画会逐帧重排工作区 → 卡顿。
            if model.section == section && !layout.isCollapsed {
                layout.sidebarWidth = 0
            } else {
                model.section = section
                if layout.isCollapsed { layout.expand() }
            }
        }
        .tooltip(title(section))
    }
}

/// 活动栏图标按钮：选中=主色高亮底，hover=淡底 + 图标提亮（与左下迷你进度环的 hover 一致）。
private struct ActivityBarButton: View {
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(selected ? Pal.mauve : (hover ? Pal.subtext : Pal.overlay))
                .frame(width: 38, height: 38)
                .background(
                    selected ? Pal.mauve.opacity(0.16) : (hover ? Pal.fill(0.08) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
    }
}
