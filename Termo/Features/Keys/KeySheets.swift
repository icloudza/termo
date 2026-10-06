import SwiftUI

/// 生成新密钥弹窗。
struct GenerateKeyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var generating = false
    @Environment(\.modalDismiss) private var dismiss

    @State private var name = ""
    @State private var type: SSHKeyType = .ed25519
    @State private var comment = ""
    @State private var passphrase = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("生成密钥").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("名称") { ThemedTextField(placeholder: "我的密钥", text: $name) }
                    labeled("类型") {
                        ThemedDropdown(options: SSHKeyType.allCases.map { (value: $0, verbatim: $0.label) },
                                       selection: $type)
                    }
                    labeled("注释") { ThemedTextField(placeholder: "user@host（可选，写入公钥尾部）", text: $comment) }
                    labeled("口令") { ThemedSecureField(placeholder: "（可选，给私钥加密）", text: $passphrase) }
                    Text("私钥安全存入系统钥匙串，绝不落盘明文；公钥可随时复制到服务器 authorized_keys。")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Hairline()
            HStack {
                Spacer()
                SecondaryButton(title: "取消") { dismiss() }
                Button {
                    generating = true
                    model.generateKey(name: name.trimmingCharacters(in: .whitespaces),
                                      type: type, comment: comment, passphrase: passphrase) { ok in
                        generating = false
                        if ok { dismiss() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        // 固定 12pt 槽位：转圈出现时按钮不变宽
                        if generating { ProgressView().controlSize(.mini).tint(.white).frame(width: 12, height: 12) }
                        Text("生成")
                    }
                }
                .buttonStyle(ThemedButtonStyle(kind: .primary))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || generating)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 420)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            content()
        }
    }
}

/// 密钥详情弹窗：查看类型/指纹/创建时间，复制公钥，删除。
struct KeyDetailView: View {
    @ObservedObject var model: AppModel
    let key: SSHKey
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.modalDismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 14)).foregroundStyle(Pal.mauve)
                Text(key.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text).lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    info(String(localized: "类型"), key.type.label)
                    info(String(localized: "指纹"), key.fingerprint.isEmpty ? "—" : key.fingerprint)
                    info(String(localized: "口令保护"), key.hasPassphrase ? String(localized: "已加密") : String(localized: "无"))
                    info(String(localized: "创建于"), Self.dateFormatter.string(from: key.createdAt))
                    if !key.comment.isEmpty { info(String(localized: "注释"), key.comment) }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("公钥").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                            Spacer()
                            Button {
                                model.copyPublicKey(key); copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }   // 反馈后复原，可再次复制
                            } label: {
                                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11)).foregroundStyle(Pal.mauve)
                            }
                            .buttonStyle(.plain).pointerCursor()
                        }
                        Text(key.publicKey)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Hairline()
            HStack {
                Button { model.requestDeleteKey(key) } label: { Text("删除") }   // 确认后由 deleteKey 关闭本弹窗
                    .buttonStyle(ThemedButtonStyle(kind: .softDestructive))
                Spacer()
                SecondaryButton(title: "关闭") { dismiss() }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 480, height: 440)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            // 最小 64 宽对齐中文标签；英文「Passphrase Protected」等更长时自动撑开，不折行。
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .fixedSize().frame(minWidth: 64, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
