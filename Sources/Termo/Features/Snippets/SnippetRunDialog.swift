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
                            ThemedTextField(placeholder: v, text: Binding(
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
