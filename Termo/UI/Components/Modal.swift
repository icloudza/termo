import AppKit
import SwiftUI

/// 窗口内弹窗的关闭动作，替代系统 sheet 的 `\.dismiss`：弹窗改为窗口内叠层后系统 dismiss 不再生效，
/// 由呈现方经环境注入；视图里照旧写 `dismiss()`。
struct ModalDismissAction {
    let action: () -> Void
    func callAsFunction() { action() }
}

private struct ModalDismissKey: EnvironmentKey {
    static let defaultValue = ModalDismissAction(action: {})
}

extension EnvironmentValues {
    var modalDismiss: ModalDismissAction {
        get { self[ModalDismissKey.self] }
        set { self[ModalDismissKey.self] = newValue }
    }
}

/// 弹窗遮罩：铺满窗口、吃掉下层点击，点空白处执行 onTap（关闭 / 取消 / 隐藏到后台）。
/// 同时登记到 Esc 栈：按 Esc 对最上层弹窗执行同一动作。
struct ModalBackdrop: View {
    var opacity: Double? = nil         // nil = 按主题取（深色 0.42 / 浅色 0.20）
    /// 是否响应 Esc。挂在常驻但被隐藏的标签里的弹窗（如未激活编辑器的保存冲突）必须传 false，否则会吞掉别处的 Esc。
    var escapable: Bool = true
    let onTap: () -> Void
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var stack = ModalEscape.observer
    @State private var escape = ModalEscape.Entry()

    /// 叠在别的弹窗上时只再加一层浅遮罩：每层都按全量压暗，三层叠起来接近全黑。
    private var dim: Double {
        let full = opacity ?? (theme.isDark ? 0.42 : 0.20)
        return ModalEscape.isBase(escape) ? full : min(full, theme.isDark ? 0.18 : 0.10)
    }

    var body: some View {
        let _ = escape.update(action: onTap, enabled: escapable)   // 随视图更新，Esc 总是执行当前这一版
        let _ = stack.version
        Color.black.opacity(dim)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .background(ModalEscape.Probe(entry: escape))
            .onAppear { ModalEscape.push(escape) }
            .onDisappear { ModalEscape.remove(escape) }
    }
}

/// Esc 关闭弹窗。弹窗都是主窗口内的叠层（不是 sheet），系统不会替它们处理 Esc。
@MainActor
enum ModalEscape {
    final class Entry {
        var action: () -> Void = {}
        var enabled = true
        weak var view: NSView?
        func update(action: @escaping () -> Void, enabled: Bool) {
            self.action = action
            self.enabled = enabled
        }
    }

    /// 遮罩在窗口里的锚点：按 Esc 时只认仍挂在窗口上的遮罩。万一某个遮罩没走 onDisappear，
    /// 也不会一直拦着 Esc（终端里 vim 离不开 Esc）。
    struct Probe: NSViewRepresentable {
        let entry: Entry
        func makeNSView(context: Context) -> NSView {
            let v = NSView()
            entry.view = v
            return v
        }
        func updateNSView(_ nsView: NSView, context: Context) { entry.view = nsView }
    }

    /// 栈变化时通知各遮罩重算深浅。
    final class Observer: ObservableObject {
        @Published var version = 0
    }
    static let observer = Observer()

    private static var stack: [Entry] = []
    private static var monitor: Any?

    /// 是否为所在窗口里最底层的可见弹窗（它负责完整压暗）。刚出现、还没挂上窗口的新弹窗按「最上层」处理。
    static func isBase(_ entry: Entry) -> Bool {
        let w = entry.view?.window
        guard let first = stack.first(where: { $0.enabled && (w == nil || $0.view?.window === w) }) else { return true }
        return first === entry
    }

    static func push(_ entry: Entry) {
        stack.removeAll { $0 === entry }
        stack.append(entry)
        observer.version &+= 1
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { handle(event) } ? nil : event
            }
        }
    }

    static func remove(_ entry: Entry) {
        stack.removeAll { $0 === entry }
        observer.version &+= 1
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let window = event.window else { return false }
        stack.removeAll { $0.view?.window == nil }
        // 只处理按键所在窗口里的弹窗：主窗口里按 Esc 不能去拒绝 RDP 独立窗口里的证书框。
        guard let top = stack.last(where: { $0.enabled && $0.view?.window === window }) else { return false }
        // 输入法正在组字时 Esc 是取消组字，不能顺手把弹窗关了。
        if let tv = window.firstResponder as? NSTextView, tv.hasMarkedText() { return false }
        top.action()
        return true
    }
}

private struct CardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct ModalPresenter<Card: View>: ViewModifier {
    let isPresented: Bool
    let onDismiss: () -> Void
    let card: () -> Card
    @State private var cardSize: CGSize = .zero

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                ZStack {
                    if isPresented {
                        ModalBackdrop(onTap: onDismiss)
                            .transition(.opacity)
                        card()
                            .environment(\.modalDismiss, ModalDismissAction(action: onDismiss))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.fill(0.08), lineWidth: 1))
                            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
                            .background(GeometryReader { Color.clear.preference(key: CardSizeKey.self, value: $0.size) })
                            // 卡片是定尺寸的（如测试连接 520×600），窗口缩到最小时会比窗口还高、被裁掉标题和按钮：放不下就等比缩小。
                            .scaleEffect(modalFitScale(cardSize, in: geo.size))
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .onPreferenceChange(CardSizeKey.self) { cardSize = $0 }
            .animation(.easeOut(duration: 0.15), value: isPresented)
            // 未呈现时整层不吃点击：避免淡出过程中残留的透明命中层挡住下方内容。
            .allowsHitTesting(isPresented)
        }
    }

}

/// 定尺寸卡片放不进可用区域时的等比缩放系数（四周留 24pt）。
private func modalFitScale(_ card: CGSize, in area: CGSize) -> CGFloat {
    guard card.width > 0, card.height > 0 else { return 1 }
    let margin: CGFloat = 24
    return min(1, (area.width - margin) / card.width, (area.height - margin) / card.height)
}

private struct FitInContainer: ViewModifier {
    let size: CGSize
    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .scaleEffect(modalFitScale(size, in: geo.size))
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

extension View {
    /// 自带遮罩的定尺寸弹窗卡片：窗口缩到放不下时等比缩小（`.modalOverlay` 已内置同样处理）。
    func fitInContainer(_ size: CGSize) -> some View {
        modifier(FitInContainer(size: size))
    }

    /// 窗口内模态弹窗（替代系统 sheet）：遮罩 + 居中卡片，点空白处关闭。卡片内可用 `@Environment(\.modalDismiss)` 关闭自身。
    func modalOverlay<Card: View>(isPresented: Bool, onDismiss: @escaping () -> Void,
                                  @ViewBuilder card: @escaping () -> Card) -> some View {
        modifier(ModalPresenter(isPresented: isPresented, onDismiss: onDismiss, card: card))
    }
}
