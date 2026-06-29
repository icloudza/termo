import SwiftUI

/// 「每次询问」主机连接前的一次性密码弹窗：密码仅本次连接使用，不写入磁盘/钥匙串。
struct AskPasswordDialog: View {
    let host: Host
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var password = ""
    @ObservedObject private var theme = ThemeManager.shared

    private var target: String {
        guard let s = host.ssh else { return host.name }
        return "\(s.user)@\(s.host)"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text("输入密码").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("连接 \(target)，仅本次使用、不保存。")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                ThemedSecureField(placeholder: "密码", text: $password)
                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: "连接", enabled: !password.isEmpty) { onConfirm(password) }
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}
