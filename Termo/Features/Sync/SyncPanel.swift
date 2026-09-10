import SwiftUI

/// 侧栏「同步」面板：WebDAV 配置 + 主密码 + 操作与状态。
/// 密码输入统一走 ThemedSecureField；主密码只存在于 SyncModel 内存，不持久化。
struct SyncPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sync = SyncModel.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                webdavSection
                Divider().overlay(Pal.fill(0.08))
                masterSection
                Divider().overlay(Pal.fill(0.08))
                actionsSection
                statusSection
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
    }

    // MARK: - WebDAV 配置

    private var webdavSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("WebDAV 服务器")
            ThemedTextField(
                verbatim: "https://dav.example.com/remote.php/dav/files/me",
                text: $sync.baseURL)
            ThemedTextField(placeholder: "用户名", text: $sync.username)
            ThemedSecureField(placeholder: "密码", text: $sync.password)
            ThemedTextField(verbatim: SyncConfigStore.defaultRemotePath, text: $sync.remotePath)
            Text("建议使用 HTTPS；远程路径第一级目录需已存在（Seafile 需先在网页端新建资料库），深层目录会自动创建。密码存系统钥匙串，不写磁盘明文。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecondaryButton(title: "测试连接") { Task { await sync.testConnection() } }
                SecondaryButton(title: "保存配置") {
                    sync.saveConfig(); sync.statusText = String(localized: "配置已保存");
                    sync.statusIsError = false
                }
            }
        }
    }

    // MARK: - 主密码

    private var masterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("主密码（端到端加密）")
            ThemedSecureField(placeholder: "主密码（至少 8 位）", text: $sync.masterPassword)
            Text("备份上传前用主密码加密，WebDAV 上只有密文；主密码不保存，各设备需一致。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 操作

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("操作")
            PrimaryButton(title: "合并同步", enabled: !sync.busy) {
                Task { await sync.mergeSync(model: model) }
            }
            SecondaryButton(title: "从 WebDAV 导入") { Task { await sync.importFromWebDAV(model: model) } }
            SecondaryButton(title: "上传本机覆盖远端") { Task { await sync.uploadLocal(model: model) } }
            SecondaryButton(title: "导出到文件…") { sync.exportToFile(model: model) }
            SecondaryButton(title: "从文件导入…") { sync.importFromFile(model: model) }
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sync.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在处理…").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
            }
            if !sync.statusText.isEmpty {
                Text(sync.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(sync.statusIsError ? Pal.red : Pal.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let last = sync.lastSyncAt {
                Text("上次同步：\(Self.formatter.string(from: last))")
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
            Text("合并按 id 双向进行，冲突时逐项选择；删除不会同步（另一端下次会带回）。语言等设置同步后需重启生效。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

/// 同步冲突裁决弹窗。挂在 ContentView 上：侧栏有 `.clipped()`，大弹窗不能放在侧栏内部。
struct SyncDialogs: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject private var sync = SyncModel.shared

    func body(content: Content) -> some View {
        content.overlay {
            if let pending = sync.pendingMerge {
                SyncConflictDialog(result: pending.result) { choices in
                    Task { await sync.resolvePending(choices: choices, model: model) }
                } onCancel: {
                    sync.cancelPending()
                }
            }
        }
    }
}

private struct SyncConflictDialog: View {
    let result: SyncMergeResult
    let onConfirm: ([String: Bool]) -> Void
    let onCancel: () -> Void
    @State private var choices: [String: Bool] = [:]
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("解决同步冲突")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Pal.text)
                    Text("以下 \(result.conflicts.count) 项在本机与远端不同，请逐项选择保留哪边。")
                        .font(.system(size: 12))
                        .foregroundStyle(Pal.subtext)
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "全部保留本机") {
                        for conflict in result.conflicts { choices[conflict.id] = true }
                    }
                    SecondaryButton(title: "全部使用远端") {
                        for conflict in result.conflicts { choices[conflict.id] = false }
                    }
                    Spacer()
                }

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(result.conflicts) { conflict in
                            row(conflict)
                            if conflict.id != result.conflicts.last?.id {
                                Divider().overlay(Pal.fill(0.06))
                            }
                        }
                    }
                    .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.fill(0.06), lineWidth: 1))
                }
                .frame(maxHeight: 300)

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: "应用") { onConfirm(choices) }
                }
            }
            .padding(20)
            .frame(width: 560)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
    }

    private func row(_ conflict: SyncConflict) -> some View {
        let keepLocal = Binding(
            get: { choices[conflict.id] ?? true },
            set: { choices[conflict.id] = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            Text(conflict.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pal.text)
            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    Text("字段")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        .frame(width: 64, alignment: .leading)
                    Text("本机")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("远端")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(conflict.fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .top, spacing: 8) {
                        Text(field.label)
                            .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                            .frame(width: 64, alignment: .leading)
                        Text(field.local.isEmpty ? "—" : field.local)
                            .font(.system(size: 11))
                            .foregroundStyle(field.isDifferent ? Pal.yellow : Pal.subtext)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2).truncationMode(.middle)
                            .tooltip(field.local)
                        Text(field.remote.isEmpty ? "—" : field.remote)
                            .font(.system(size: 11))
                            .foregroundStyle(field.isDifferent ? Pal.yellow : Pal.subtext)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2).truncationMode(.middle)
                            .tooltip(field.remote)
                    }
                }
            }
            SegmentedControl(
                options: [(value: true, label: "保留本机"), (value: false, label: "使用远端")],
                selection: keepLocal
            )
            .frame(width: 220)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
