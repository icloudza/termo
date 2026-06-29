import AppKit
import SwiftUI

/// RDP 远程桌面证书信任弹窗（首连验证 / 证书变更复核）。
/// 卡片式弹窗：勾选「始终信任此电脑」则永久信任并写入 [[RDPCertTrustStore]]，
/// 否则仅本次接受；取消则拒绝连接。changed=true 时显示更强的中间人警告。
struct RDPCertDialog: View {
    let prompt: RDPCertPrompt
    @State private var alwaysTrust = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // 标题栏：首连用锁、变更用警告三角
                HStack(spacing: 10) {
                    Image(systemName: prompt.changed ? "exclamationmark.triangle.fill" : "lock.shield.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(prompt.changed ? Pal.red : Pal.yellow)
                    Text(prompt.changed ? "警告：远程桌面证书已更改" : "首次连接：验证远程桌面证书")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                    Spacer()
                }
                .padding(.bottom, 14)

                Text(prompt.changed
                     ? "该主机的证书与上次信任的不一致。若非你主动更换证书，可能存在中间人窃听风险，请谨慎确认。"
                     : "无法将此证书反向验证到受信任的根证书（自签名证书常见于内网/个人服务器）。请核对指纹后再决定是否信任。")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)

                infoRow("目标", "\(prompt.host):\(prompt.port)", mono: true)
                if let s = prompt.subject, !s.isEmpty { infoRow("主体", s) }
                if let i = prompt.issuer, !i.isEmpty { infoRow("颁发者", i) }

                HStack {
                    Text("证书指纹（建议与服务器核对）")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                    Spacer()
                    copyButton("复制指纹", prompt.fingerprint)
                }
                .padding(.top, 6).padding(.bottom, 8)

                Text(prompt.fingerprint.isEmpty ? "（无指纹信息）" : prompt.fingerprint)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Pal.subtext).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if prompt.changed, let old = prompt.oldFingerprint, !old.isEmpty {
                    Text("原信任指纹：\(old)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Pal.overlay).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }

                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: alwaysTrust) { alwaysTrust.toggle() }
                    Text("始终信任此电脑（\(prompt.host)）")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { alwaysTrust.toggle() }
                }
                .padding(.top, 18).padding(.bottom, 20)

                HStack(spacing: 10) {
                    Spacer()
                    Button { prompt.respond(.reject) } label: {
                        Text("取消").font(.system(size: 13)).foregroundStyle(Pal.text)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.10), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button { prompt.respond(alwaysTrust ? .trust : .once) } label: {
                        Text("继续").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(prompt.changed ? Pal.red : Pal.green, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(22)
            .frame(width: 520)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text("\(label)：").font(.system(size: 13)).foregroundStyle(Pal.overlay)
            Text(value)
                .font(.system(size: 13, design: mono ? .monospaced : .default))
                .foregroundStyle(Pal.subtext).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.bottom, 6)
    }

    private func copyButton(_ title: String, _ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Text(title).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Pal.fill(0.10), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(!value.isEmpty)
        .disabled(value.isEmpty)
        .opacity(value.isEmpty ? 0.4 : 1)
    }
}
