import SwiftUI

/// 「密钥」活动栏分区的侧栏面板：列出受管密钥，支持搜索、查看详情、复制公钥、删除。
struct KeysPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    private var keys: [SSHKey] {
        let q = model.query.lowercased()
        guard !q.isEmpty else { return model.sshKeys }
        return model.sshKeys.filter {
            $0.name.lowercased().contains(q)
                || $0.fingerprint.lowercased().contains(q)
                || $0.comment.lowercased().contains(q)
        }
    }

    var body: some View {
        if model.sshKeys.isEmpty {
            emptyState
        } else if keys.isEmpty {
            VStack(spacing: 10) {
                Spacer().frame(height: 40)
                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                Text("无匹配密钥").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(keys) { KeyRow(key: $0, model: model) }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: "key").font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text("还没有密钥").font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("生成新密钥，或导入已有私钥").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            HStack(spacing: 8) {
                Button { model.showGenerateKey = true } label: {
                    Text("生成").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Button { model.presentImportKey() } label: {
                    Text("导入").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

private struct KeyRow: View {
    let key: SSHKey
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        Button { model.detailKey = key } label: {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 13)).foregroundStyle(Pal.mauve).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.name).font(.system(size: 13)).foregroundStyle(Pal.text).lineLimit(1)
                    Text("\(key.type.label) · \(shortFingerprint)")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay).lineLimit(1)
                }
                Spacer(minLength: 0)
                if key.hasPassphrase {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hover ? Pal.fill(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .contextMenu {
            Button("复制公钥") { model.copyPublicKey(key) }
            Button("查看详情") { model.detailKey = key }
            Divider()
            Button("删除", role: .destructive) { model.deleteKey(key) }
        }
    }

    /// SHA256 指纹缩略：SHA256:abc123…wxyz
    private var shortFingerprint: String {
        let raw = key.fingerprint.replacingOccurrences(of: "SHA256:", with: "")
        guard raw.count > 14 else { return key.fingerprint }
        return "SHA256:\(raw.prefix(6))…\(raw.suffix(4))"
    }
}
