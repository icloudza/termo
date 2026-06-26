import SwiftUI

/// 自定义分段控件，风格统一、主题自适应。
struct SegmentedControl<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    @ObservedObject private var theme = ThemeManager.shared
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let selected = selection == opt.value
                Text(opt.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Pal.text : Pal.subtext)
                    .padding(.horizontal, 14)
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
struct ThemedTextField: View {
    let placeholder: String
    @Binding var text: String
    var autofocus: Bool = false
    var onSubmit: (() -> Void)? = nil
    @FocusState private var focused: Bool
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
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
    let placeholder: String
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
    let placeholder: String
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
                SecureField(placeholder, text: $text)
                    .focused($focusedField, equals: .secure)
                    .opacity(reveal ? 0 : 1)
                    .allowsHitTesting(!reveal)
                TextField(placeholder, text: $text)
                    .focused($focusedField, equals: .plain)
                    .opacity(reveal ? 1 : 0)
                    .allowsHitTesting(reveal)
            }
            .textFieldStyle(.plain)
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
    let options: [(value: T, label: String)]
    @Binding var selection: T
    @State private var open = false
    @ObservedObject private var theme = ThemeManager.shared

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label ?? ""
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(currentLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(Pal.text)
                Spacer()
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
        .animation(.easeOut(duration: 0.12), value: open)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 1) {
                ForEach(options, id: \.value) { opt in
                    DropdownOption(
                        label: opt.label,
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
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Pal.mauve : Pal.text)
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
        .onHover { hover = $0 }
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
    }
}

/// 居中确认对话框（带半透明遮罩），替代系统模态弹窗。
struct ConfirmDialog: View {
    let title: String
    let message: String
    var confirmTitle: String = "确认"
    var cancelTitle: String = "取消"
    var destructive: Bool = false
    var showCancel: Bool = true   // 纯提示型弹窗设 false，仅保留确认按钮
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer()
                    if showCancel { SecondaryButton(title: cancelTitle, action: onCancel) }
                    Button(action: onConfirm) {
                        Text(confirmTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background((destructive ? Pal.red : Pal.mauve), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
    let title: String
    var enabled: Bool = true
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Pal.mauve.opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 次要操作按钮。
struct SecondaryButton: View {
    let title: String
    let action: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Pal.subtext)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
