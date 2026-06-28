import SwiftUI

/// 重命名弹窗（自定义样式，与 ConfirmDialog 一致）。
struct RenameDialog: View {
    let originalName: String
    let title: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @ObservedObject private var theme = ThemeManager.shared

    init(originalName: String, title: String = "重命名",
         onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.originalName = originalName
        self.title = title
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = State(initialValue: originalName)
    }

    private var canConfirm: Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.contains("/")
    }
    private func submit() { if canConfirm { onConfirm(name) } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                ThemedTextField(placeholder: "名称", text: $name, autofocus: true, onSubmit: submit)
                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: "确定", enabled: canConfirm, action: submit)
                }
            }
            .padding(20).frame(width: 360)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}

/// 权限弹窗：属主/用户组/其他 × 读/写/执行 复选九宫格 + 同步八进制。
struct ChmodDialog: View {
    let fileName: String
    let onConfirm: (Int) -> Void
    let onCancel: () -> Void
    @State private var mode: Int
    @State private var octalText: String
    @ObservedObject private var theme = ThemeManager.shared

    init(fileName: String, initialMode: Int, onConfirm: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.fileName = fileName
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _mode = State(initialValue: initialMode & 0o777)
        _octalText = State(initialValue: String(format: "%03o", initialMode & 0o777))
    }

    private let groups: [(label: String, shift: Int)] = [("属主", 6), ("用户组", 3), ("其他", 0)]
    private let perms: [(label: String, bit: Int)] = [("读", 4), ("写", 2), ("执行", 1)]

    private func isOn(_ shift: Int, _ bit: Int) -> Bool { (mode >> shift) & bit != 0 }
    private func toggle(_ shift: Int, _ bit: Int) {
        mode ^= (bit << shift)
        octalText = String(format: "%03o", mode)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 12) {
                Text("权限").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text(fileName).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Pal.subtext).lineLimit(1).truncationMode(.middle)

                grid.padding(.top, 2)

                HStack(spacing: 8) {
                    Text("权限码").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    ThemedTextField(placeholder: "755", text: $octalText)
                        .frame(width: 72)
                        .onChange(of: octalText) { t in
                            // 仅取末 3 位八进制数字解析回 mode；不反写 octalText，避免回环更新
                            let digits = String(t.filter { "01234567".contains($0) }.suffix(3))
                            if let v = Int(digits, radix: 8) { mode = v & 0o777 }
                        }
                    Spacer()
                    Text(symbolic).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
                }

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: "应用") { onConfirm(mode & 0o777) }
                }
                .padding(.top, 2)
            }
            .padding(20).frame(width: 340)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }

    private var grid: some View {
        VStack(spacing: 9) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 60, height: 14)   // 占位：必须同时定高，否则纵向贪婪扩展撑满弹窗
                ForEach(perms, id: \.label) { p in
                    Text(p.label).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .frame(width: 50)
                }
            }
            ForEach(groups, id: \.label) { g in
                HStack(spacing: 0) {
                    Text(g.label).font(.system(size: 12)).foregroundStyle(Pal.text)
                        .frame(width: 60, alignment: .leading)
                    ForEach(perms, id: \.label) { p in
                        ThemedCheckbox(isOn: isOn(g.shift, p.bit)) { toggle(g.shift, p.bit) }
                            .frame(width: 50)
                    }
                }
            }
        }
    }

    /// rwxr-xr-x 风格展示。
    private var symbolic: String {
        var s = ""
        for g in groups {
            s += isOn(g.shift, 4) ? "r" : "-"
            s += isOn(g.shift, 2) ? "w" : "-"
            s += isOn(g.shift, 1) ? "x" : "-"
        }
        return s
    }
}
