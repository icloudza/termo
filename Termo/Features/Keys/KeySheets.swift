import SwiftUI

/// 生成新密钥弹窗。
struct GenerateKeyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

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
            Divider().overlay(Pal.fill(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("名称") { ThemedTextField(placeholder: "我的密钥", text: $name) }
                    labeled(String(localized: "类型")) {
                        ThemedDropdown(options: SSHKeyType.allCases.map { (value: $0, label: $0.label) },
                                       selection: $type)
                    }
                    labeled("注释") { ThemedTextField(placeholder: "user@host（可选，写入公钥尾部）", text: $comment) }
                    labeled(String(localized: "口令")) { ThemedSecureField(placeholder: "（可选，给私钥加密）", text: $passphrase) }
                    Text("私钥安全存入系统钥匙串，绝不落盘明文；公钥可随时复制到服务器 authorized_keys。")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Pal.fill(0.06))
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text("取消").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Button {
                    model.generateKey(name: name.trimmingCharacters(in: .whitespaces),
                                      type: type, comment: comment, passphrase: passphrase)
                    dismiss()
                } label: {
                    Text("生成").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 420)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
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
    @Environment(\.dismiss) private var dismiss
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
            Divider().overlay(Pal.fill(0.06))

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

            Divider().overlay(Pal.fill(0.06))
            HStack {
                Button {
                    model.deleteKey(key); dismiss()
                } label: {
                    Text("删除").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.red)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer()
                Button { dismiss() } label: {
                    Text("关闭").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 480, height: 440)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext).frame(width: 64, alignment: .leading)
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
