import SwiftUI

/// 含 {{变量}} 的片段在运行/插入前的填值弹窗：逐个变量收集值，确认后替换并发送到终端。
/// 复用「每次询问」密码弹窗那套居中 overlay 风格。
struct SnippetRunDialog: View {
    let request: SnippetRunRequest
    let onConfirm: ([String: String]) -> Void
    let onCancel: () -> Void
    @State private var values: [String: String] = [:]
    @ObservedObject private var theme = ThemeManager.shared

    private var allFilled: Bool {
        request.variables.allSatisfy { !(values[$0] ?? "").isEmpty }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text(request.run ? "运行片段" : "插入片段")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("「\(request.snippet.name)」需要填入以下变量：")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(request.variables, id: \.self) { v in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(v).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                            ThemedTextField(verbatim: v, text: Binding(
                                get: { values[v] ?? "" },
                                set: { values[v] = $0 }
                            ))
                        }
                    }
                }
                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: request.run ? "运行" : "插入", enabled: allFilled) { onConfirm(values) }
                }
            }
            .padding(20)
            .frame(width: 380)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}

/// 片段「默认动作」为「每次询问」时的选择弹窗：插入还是运行 + 是否记住。
/// 「仅插入」为主按钮（安全，不直接执行）；勾选记住后写入设置、之后不再询问（可在设置里改回）。
struct SnippetActionDialog: View {
    let snippet: Snippet
    let onChoose: (_ run: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void
    @State private var remember = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text("使用片段").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("「\(snippet.name)」要如何发送到当前终端？")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: remember) { remember.toggle() }
                    Text("记住我的选择（可在设置中修改）")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { remember.toggle() }
                }
                HStack(spacing: 10) {
                    SecondaryButton(title: "取消", action: onCancel)
                    Spacer()
                    SecondaryButton(title: "直接运行") { onChoose(true, remember) }
                    PrimaryButton(title: "仅插入") { onChoose(false, remember) }
                }
            }
            .padding(20)
            .frame(width: 400)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}
