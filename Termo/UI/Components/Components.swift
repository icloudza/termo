import SwiftUI
import AppKit

private struct TruncWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 单行文本：内容溢出被截断时整段可点击 → 弹出可复制的完整内容预览；未截断则不可点击。
/// 用于端口转发失败原因等可能很长的单行信息。
struct TruncatableText: View {
    let text: String
    var fontSize: CGFloat = 11
    var color: Color = Pal.red

    @State private var available: CGFloat = 0
    @State private var showPreview = false
    @State private var copied = false

    /// 实测文本全宽 > 实际可用宽 ⇒ 被截断。
    private var isTruncated: Bool {
        guard available > 0 else { return false }
        let w = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return w > available + 1
    }

    var body: some View {
        Text(text)
            .font(.system(size: fontSize))
            .foregroundStyle(color)
            .lineLimit(1)
            .background(GeometryReader { g in
                Color.clear.preference(key: TruncWidthKey.self, value: g.size.width)
            })
            .onPreferenceChange(TruncWidthKey.self) { available = $0 }
            .contentShape(Rectangle())
            .onTapGesture { if isTruncated { showPreview = true } }
            .pointerCursor(isTruncated)
            .help(isTruncated ? "点击查看完整内容（可复制）" : "")
            .popover(isPresented: $showPreview, arrowEdge: .bottom) { preview }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                        Text(copied ? "已复制" : "复制").font(.system(size: 12))
                    }
                    .foregroundStyle(copied ? Pal.green : Pal.mauve)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background((copied ? Pal.green : Pal.mauve).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(14).frame(width: 380)
    }
}

/// 自定义分段控件，风格统一、主题自适应。
struct SegmentedControl<T: Hashable>: View {
    let options: [(value: T, label: Text)]
    @Binding var selection: T
    @ObservedObject private var theme = ThemeManager.shared
    @Namespace private var ns

    // 静态 UI 文案：LocalizedStringKey，字面量自动进 String Catalog。
    init(options: [(value: T, label: LocalizedStringKey)], selection: Binding<T>) {
        self.options = options.map { ($0.value, Text($0.label)) }
        self._selection = selection
    }
    // 动态数据（枚举 rawValue/title 等）：verbatim，不本地化。
    init(options: [(value: T, verbatim: String)], selection: Binding<T>) {
        self.options = options.map { ($0.value, Text(verbatim: $0.verbatim)) }
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let selected = selection == opt.value
                opt.label
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Pal.text : Pal.subtext)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)   // 长文案（如英文）缩放保持单行，不换行撑高
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.isDark ? Pal.fill(0.14) : Color.white)
                                .shadow(color: .black.opacity(theme.isDark ? 0.25 : 0.12), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .pointerCursor()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { selection = opt.value }
                    }
            }
        }
        .padding(3)
        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// 主题自适应的输入框（聚焦时高亮强调色边框）。
extension View {
    /// 去掉 macOS 原生输入框聚焦时的系统蓝光环（focus ring）。焦点反馈统一改用自定义描边，符合「禁止原生外观」。
    func noNativeFocusRing() -> some View {
        focusEffectDisabled()   // 最低系统 macOS 14，此 API 恒可用
    }
}

extension Binding where Value == String {
    /// 单行输入的去换行代理绑定：粘贴含 \n/\r 的内容时即时剥掉换行，
    /// 防止单行输入框（密码/名称等）被多行内容撑高。多行输入（ThemedTextEditor）不用此绑定。
    var singleLine: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0.filter { !$0.isNewline } })
    }
}

struct ThemedTextField: View {
    private let prompt: Text
    @Binding var text: String
    var autofocus: Bool = false
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool
    @ObservedObject private var theme = ThemeManager.shared

    // 静态 UI 文案：LocalizedStringKey，字面量自动进 String Catalog。
    init(placeholder: LocalizedStringKey, text: Binding<String>, autofocus: Bool = false, onSubmit: (() -> Void)? = nil) {
        self.prompt = Text(placeholder); self._text = text; self.autofocus = autofocus; self.onSubmit = onSubmit
    }
    // 动态数据（片段变量名等）：verbatim，不本地化。
    init(verbatim placeholder: String, text: Binding<String>, autofocus: Bool = false, onSubmit: (() -> Void)? = nil) {
        self.prompt = Text(verbatim: placeholder); self._text = text; self.autofocus = autofocus; self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(text: $text.singleLine, prompt: prompt) { EmptyView() }
            .textFieldStyle(.plain)
            .lineLimit(1)
            .noNativeFocusRing()
            .font(.system(size: 13))
            .foregroundStyle(Pal.text)
            .focused($focused)
            .onSubmit { onSubmit?() }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(focused ? Pal.mauve : Pal.fill(0.12), lineWidth: focused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: focused)
            .onAppear { if autofocus { focused = true } }
    }
}

/// 多行输入框。
struct ThemedTextEditor: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    @FocusState private var focused: Bool
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Pal.overlay)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Pal.text)
                .focused($focused)
                .noNativeFocusRing()
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
        }
        .frame(height: 80)
        .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(focused ? Pal.mauve : Pal.fill(0.12), lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// 密码输入框（带显示/隐藏小眼睛）。
struct ThemedSecureField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    @State private var reveal = false
    @FocusState private var focusedField: Field?
    @ObservedObject private var theme = ThemeManager.shared

    private enum Field { case secure, plain }
    private var isFocused: Bool { focusedField != nil }

    var body: some View {
        HStack(spacing: 6) {
            // 两个字段都常驻、仅切 opacity；切换显示/隐藏时不重建视图，焦点不丢失
            ZStack {
                SecureField(placeholder, text: $text.singleLine)
                    .focused($focusedField, equals: .secure)
                    .opacity(reveal ? 0 : 1)
                    .allowsHitTesting(!reveal)
                TextField(placeholder, text: $text.singleLine)
                    .focused($focusedField, equals: .plain)
                    .opacity(reveal ? 1 : 0)
                    .allowsHitTesting(reveal)
            }
            .textFieldStyle(.plain)
            .lineLimit(1)
            .noNativeFocusRing()
            .font(.system(size: 13))
            .foregroundStyle(Pal.text)

            Button {
                let wasFocused = isFocused
                reveal.toggle()
                // 把焦点移到当前可见的字段；两者都在视图树中，重设焦点可靠
                if wasFocused {
                    DispatchQueue.main.async { focusedField = reveal ? .plain : .secure }
                }
            } label: {
                Image(systemName: reveal ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(isFocused ? Pal.subtext : Pal.overlay)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(reveal ? "隐藏密码" : "显示密码")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Pal.mauve : Pal.fill(0.12), lineWidth: isFocused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

/// 主题自适应下拉菜单（基于 popover 全自定义实现）。
struct ThemedDropdown<T: Hashable>: View {
    let options: [(value: T, label: Text)]
    @Binding var selection: T
    @State private var open = false
    @ObservedObject private var theme = ThemeManager.shared

    // 静态 UI 文案：LocalizedStringKey，字面量自动进 String Catalog。
    init(options: [(value: T, label: LocalizedStringKey)], selection: Binding<T>) {
        self.options = options.map { ($0.value, Text($0.label)) }
        self._selection = selection
    }
    // 动态数据（编码/算法/枚举 rawValue 等）：verbatim，不本地化。
    init(options: [(value: T, verbatim: String)], selection: Binding<T>) {
        self.options = options.map { ($0.value, Text(verbatim: $0.verbatim)) }
        self._selection = selection
    }

    private var currentLabel: Text {
        options.first(where: { $0.value == selection })?.label ?? Text(verbatim: "")
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                currentLabel
                    .font(.system(size: 13))
                    .foregroundStyle(Pal.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)   // 英文较长时缩字号保持单行，不换行变胖
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.overlay)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(open ? Pal.mauve : Pal.fill(0.12), lineWidth: open ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.12), value: open)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 1) {
                ForEach(options, id: \.value) { opt in
                    DropdownOption(
                        text: opt.label,
                        selected: opt.value == selection
                    ) {
                        selection = opt.value
                        open = false
                    }
                }
            }
            .padding(6)
            .frame(minWidth: 180)
            .background(Pal.solidMantle)
        }
    }
}

private struct DropdownOption: View {
    let label: Text
    let selected: Bool
    var leadingSymbol: String? = nil      // 非 nil 时在标签前画一个强调色小图标（如「新建」的 plus）
    let action: () -> Void
    @State private var hover = false

    // 静态 UI 文案：走 LocalizedStringKey，字面量自动进 String Catalog。
    init(label: LocalizedStringKey, selected: Bool, leadingSymbol: String? = nil, action: @escaping () -> Void) {
        self.label = Text(label); self.selected = selected; self.leadingSymbol = leadingSymbol; self.action = action
    }
    // 动态数据（分组名/用户输入）：verbatim，不本地化。
    init(verbatim label: String, selected: Bool, leadingSymbol: String? = nil, action: @escaping () -> Void) {
        self.label = Text(verbatim: label); self.selected = selected; self.leadingSymbol = leadingSymbol; self.action = action
    }
    // 由上游（ThemedDropdown）预构建好的 Text 直接透传。
    init(text label: Text, selected: Bool, leadingSymbol: String? = nil, action: @escaping () -> Void) {
        self.label = label; self.selected = selected; self.leadingSymbol = leadingSymbol; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Pal.mauve)
                }
                label
                    .font(.system(size: 13))
                    .foregroundStyle(leadingSymbol != nil ? Pal.mauve : (selected ? Pal.mauve : Pal.text))
                    .lineLimit(1)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Pal.mauve)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                hover ? Pal.fill(0.08) : (selected ? Pal.mauve.opacity(0.10) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
    }
}

/// 可搜索的自定义下拉选择（combobox）：弹层顶部带搜索框，输入即过滤；
/// 输入了现有项里没有的值时给出「新建」入口。绑定到一个字符串（最终值），
/// 既能从已有项里选，也能直接键入新值。视觉与 [[ThemedDropdown]] 一致。
/// 用于「服务器/RDP/代码片段」的分组选择——分组一多，原来的横排 chip 就挤了。
struct SearchableSelect: View {
    let options: [String]
    @Binding var text: String
    var placeholder: String = "搜索或输入新分组…"
    var emptyLabel: String = "未分组"      // text 为空时按钮显示的占位文案
    var allowsCreate: Bool = true

    @State private var open = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @ObservedObject private var theme = ThemeManager.shared

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var filtered: [String] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return options }
        return options.filter { $0.lowercased().contains(q) }
    }

    private var canCreate: Bool {
        allowsCreate && !trimmedQuery.isEmpty
            && !options.contains { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
    }

    var body: some View {
        Button { toggle() } label: {
            HStack(spacing: 8) {
                Text(text.isEmpty ? emptyLabel : text)
                    .font(.system(size: 13))
                    .foregroundStyle(text.isEmpty ? Pal.overlay : Pal.text)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.overlay)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(open ? Pal.mauve : Pal.fill(0.12), lineWidth: open ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.12), value: open)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                    TextField(placeholder, text: $query.singleLine)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Pal.text)
                        .lineLimit(1)
                        .noNativeFocusRing()
                        .focused($searchFocused)
                        .onSubmit { commitQuery() }
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(theme.isDark ? Pal.fill(0.06) : Color.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.fill(0.12), lineWidth: 1))

                ScrollView {
                    VStack(spacing: 1) {
                        if canCreate {
                            DropdownOption(verbatim: "新建「\(trimmedQuery)」", selected: false, leadingSymbol: "plus") {
                                select(trimmedQuery)
                            }
                        }
                        ForEach(filtered, id: \.self) { opt in
                            // 再次点击已选中的项即取消选择（回到「未分组」）；点其它项则切换选中。
                            DropdownOption(verbatim: opt, selected: opt == text) {
                                if opt == text { deselect() } else { select(opt) }
                            }
                        }
                        if filtered.isEmpty && !canCreate {
                            Text("无匹配项").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .padding(8)
            .frame(width: 240)
            .background(Pal.solidMantle)
        }
    }

    private func toggle() {
        open.toggle()
        if open { query = ""; DispatchQueue.main.async { searchFocused = true } }
    }

    private func select(_ v: String) { text = v; open = false }

    /// 取消选择：清空为「未分组」并收起。
    private func deselect() { text = ""; open = false }

    /// 回车提交：精确匹配已有项则选中，否则在允许时按新建处理。
    private func commitQuery() {
        if let exact = options.first(where: { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }) {
            select(exact)
        } else if canCreate {
            select(trimmedQuery)
        }
    }
}

/// 放进 sheet 背景即可：阻止打开时自动把光标聚焦到第一个文本框。
/// 关键在「时机」——必须在窗口成为 key 之前就把初始第一响应者指向一个**不接受焦点**的占位视图，
/// 这样 AppKit 自动选首个文本框那一步直接落空，不会出现「先聚焦再取消」的闪烁。
/// 用户点击字段仍可正常聚焦，只是不在弹出瞬间默认抢焦。
struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusSink() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FocusSink: NSView {
        override var acceptsFirstResponder: Bool { false }
        // 视图刚挂到窗口时（早于窗口成为 key）即接管初始第一响应者，抢在自动聚焦之前。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
        }
    }
}

/// 自定义步进器（数值加减）。
struct ThemedStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...100
    var step: Int = 1
    var suffix: String = ""
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus") {
                value = max(range.lowerBound, value - step)
            }
            Divider().frame(height: 16).overlay(Pal.fill(0.10))
            Text("\(value)\(suffix)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Pal.text)
                .frame(minWidth: 46)
            Divider().frame(height: 16).overlay(Pal.fill(0.10))
            stepButton("plus") {
                value = min(range.upperBound, value + step)
            }
        }
        .background(theme.isDark ? Pal.fill(0.05) : Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.12), lineWidth: 1))
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Pal.subtext)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// 自定义开关。
struct ThemedToggle: View {
    @Binding var isOn: Bool
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Pal.mauve : Pal.fill(0.18))
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// 自定义勾选框（与 ThemedToggle 同视觉语言：选中=mauve 填充 + 白勾；未选=描边空框）。
struct ThemedCheckbox: View {
    let isOn: Bool
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { action() }
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(isOn ? Pal.mauve : Pal.fill(0.10))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(isOn ? Color.clear : Pal.fill(0.22), lineWidth: 1))
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// 居中确认对话框（带半透明遮罩），替代系统模态弹窗。
struct ConfirmDialog: View {
    private let title: Text
    private let message: Text
    var confirmTitle: LocalizedStringKey = "确认"
    var cancelTitle: LocalizedStringKey = "取消"
    var destructive: Bool = false
    var showCancel: Bool = true   // 纯提示型弹窗设 false，仅保留确认按钮
    var busy: Bool = false         // 确认操作进行中：确认键旁显示转圈并禁用，取消键仍可点（中途取消）
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    // 静态 UI 文案：title/message 走 LocalizedStringKey，字面量自动进 String Catalog。
    init(title: LocalizedStringKey, message: LocalizedStringKey,
         confirmTitle: LocalizedStringKey = "确认", cancelTitle: LocalizedStringKey = "取消",
         destructive: Bool = false, showCancel: Bool = true, busy: Bool = false,
         onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.title = Text(title); self.message = Text(message)
        self.confirmTitle = confirmTitle; self.cancelTitle = cancelTitle
        self.destructive = destructive; self.showCancel = showCancel; self.busy = busy
        self.onConfirm = onConfirm; self.onCancel = onCancel
    }
    // 动态数据（含标签名/数量等运行时字符串）：title/message 走 verbatim，不本地化。
    init(verbatimTitle title: String, verbatimMessage message: String,
         confirmTitle: LocalizedStringKey = "确认", cancelTitle: LocalizedStringKey = "取消",
         destructive: Bool = false, showCancel: Bool = true, busy: Bool = false,
         onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.title = Text(verbatim: title); self.message = Text(verbatim: message)
        self.confirmTitle = confirmTitle; self.cancelTitle = cancelTitle
        self.destructive = destructive; self.showCancel = showCancel; self.busy = busy
        self.onConfirm = onConfirm; self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                title
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)
                message
                    .font(.system(size: 13))
                    .foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer()
                    if showCancel { SecondaryButton(title: cancelTitle, action: onCancel) }
                    if busy { ProgressView().controlSize(.small) }   // 进行中：确认键旁转圈
                    Button(action: onConfirm) {
                        Text(confirmTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background((destructive ? Pal.red : Pal.mauve).opacity(busy ? 0.6 : 1),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .pointerCursor(!busy)
                }
            }
            .padding(20)
            .frame(width: 340)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
    }
}

/// 主要操作按钮（强调色填充）。
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var enabled: Bool = true
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Pal.mauve.opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pointerCursor(enabled)
    }
}

/// 次要操作按钮。
struct SecondaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Pal.subtext)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
