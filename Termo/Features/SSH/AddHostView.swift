import AppKit
import SwiftUI

struct AddHostView: View {
    @ObservedObject var model: AppModel
    var editing: Host? = nil
    @StateObject private var draft = HostDraft()
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.modalDismiss) private var dismiss
    @State private var section: HostFormSection = .basic
    @State private var didLoad = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            HStack(spacing: 0) {
                navSidebar
                Hairline(vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Hairline()
            footer
        }
        .frame(width: 680, height: 560)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let editing {
                draft.load(from: editing)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Text(isEditing ? "编辑主机" : "新增主机")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Pal.text)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - 左侧导航

    private var navSidebar: some View {
        VStack(spacing: 2) {
            ForEach(HostFormSection.allCases, id: \.self) { s in
                let selected = section == s
                Button {
                    section = s
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? Pal.mauve : Pal.overlay)
                            .frame(width: 18)
                        Text(s.label)
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? Pal.text : Pal.subtext)
                            .lineLimit(1).minimumScaleFactor(0.85)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        selected ? Pal.mauve.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 176)   // 英文「Connection Settings」等在 150 宽里会折成两行
        .frame(maxHeight: .infinity)
        .background(Pal.solidMantle)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.testConnectionDraft = draft
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                    Text("测试连接")
                }
            }
            .buttonStyle(ThemedButtonStyle(kind: .tinted))
            .disabled(!draft.canSave)

            // 按钮为什么点不了：缺哪项、哪项不合法（可能在别的分页里，不提示就找不到）。
            if let blocker = draft.saveBlocker {
                Text(blocker).font(.system(size: 11)).foregroundStyle(Pal.overlay).lineLimit(1)
            }

            Spacer()
            SecondaryButton(title: "取消") { dismiss() }
            PrimaryButton(title: isEditing ? "保存" : "添加", enabled: draft.canSave) { save() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func save() {
        if let editing {
            model.updateHost(id: editing.id, from: draft)
        } else {
            model.addHost(from: draft)
        }
        dismiss()
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true   // ~/.ssh 为隐藏目录，需显示隐藏文件才能选到密钥
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.prompt = String(localized: "选择")
        if panel.runModal() == .OK, let url = panel.url {
            if AppEnv.isMAS {
                // 沙盒下不能长期持有容器外路径 → 选中即导入密钥库，改用 keyId。
                if let key = model.importKey(from: url) { draft.keyId = key.id; draft.keyPath = "" }
            } else {
                draft.keyPath = url.path
            }
        }
    }

    /// 「密钥来源」下拉选项：手动文件 + 密钥库中的每把密钥。
    private var keySourceOptions: [(value: String, label: String)] {
        [(value: "", label: String(localized: "手动指定文件…"))]
            + model.sshKeys.map { (value: $0.id, label: "\($0.name)（\($0.type.label)）") }
    }

    // MARK: - 各分区内容

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .basic: basicSection
        case .connection: connectionSection
        case .initial: initialSection
        case .proxy: proxySection
        case .advanced: advancedSection
        }
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "基本信息"))
            groupSelector
            field(String(localized: "名称"), placeholder: "我的服务器", text: $draft.name)
            HStack(spacing: 12) {
                field(String(localized: "地址"), placeholder: "192.168.1.1 或 example.com", text: $draft.address)
                field(String(localized: "端口"), placeholder: "22", text: $draft.port).frame(width: 90)
            }
            labeled(String(localized: "验证方式")) {
                ThemedDropdown(
                    options: AuthMethod.selectable.map { (value: $0, verbatim: $0.label) },
                    selection: $draft.authMethod
                )
                .frame(width: 200)
            }
            field(String(localized: "登录用户"), placeholder: "root", text: $draft.user)
            if draft.authMethod == .key {
                labeled(String(localized: "密钥来源")) {
                    ThemedDropdown(options: keySourceOptions.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.keyId)
                }
                if draft.keyId.isEmpty {
                    labeled(String(localized: "私钥文件")) {
                        if AppEnv.isMAS {
                            // 沙盒下不接受手填路径（容器外读不到）：选文件即导入密钥库。
                            SecondaryButton(title: "选择文件并导入密钥库…") { chooseKeyFile() }
                        } else {
                            HStack(spacing: 8) {
                                ThemedTextField(placeholder: "~/.ssh/id_ed25519", text: $draft.keyPath)
                                SecondaryButton(title: "选择…") { chooseKeyFile() }
                            }
                        }
                    }
                }
                labeled(String(localized: "私钥密码"), optional: true) {
                    ThemedSecureField(placeholder: "（私钥有 passphrase 时填写）", text: $draft.password)
                }
            } else if draft.authMethod == .password {
                labeled(String(localized: "登录密码"), optional: true) {
                    ThemedSecureField(placeholder: "（可选）", text: $draft.password)
                }
            } else if draft.authMethod == .agent {
                labeled(String(localized: "Agent 套接字"), optional: true) {
                    AgentSocketField(path: $draft.agentPath,
                                     placeholder: String(localized: "留空使用「设置 › 安全」中的 Agent"),
                                     fallback: AppSettings.shared.sshAgentPath)
                }
                Text("用 SSH Agent（1Password、Secretive、系统 ssh-agent 等）里的密钥登录，私钥不经过 Termo；Agent 可能会弹出 Touch ID 等授权确认。")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 每次询问：不保存任何凭证，连接时弹窗输入本次密码。
                Text("每次连接时弹窗输入本次密码，不保存任何凭证。")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)
            }
            labeled(String(localized: "主机备注")) {
                ThemedTextEditor(placeholder: "备注信息…", text: $draft.notes)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "连接设置"))
            field(String(localized: "超时时间 (ms)"), placeholder: "10000", text: $draft.timeout)
            field(String(localized: "心跳时间 (ms)"), placeholder: "5000", text: $draft.heartbeat)
        }
    }

    private var initialSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "初始选项"))
            field(String(localized: "默认路径"), placeholder: "~", text: $draft.defaultPath)
            labeled(String(localized: "初始执行")) {
                ThemedTextEditor(placeholder: "#!/bin/bash", text: $draft.initialCommand)
            }
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "代理设置"))
            hintBox([
                String(localized: "选择此选项后，数据将会通过代理进行中转传输。"),
                String(localized: "支持 socks4/socks5 代理，如：socks5://127.0.0.1:10808（鉴权：socks5://user:pass@host:port）"),
                String(localized: "支持 http 代理，如：http://127.0.0.1:10809（鉴权：http://user:pass@host:port）"),
                String(localized: "https:// 与 http:// 相同，按 HTTP CONNECT 建立隧道（不支持与代理之间的 TLS 加密连接）"),
            ])
            toggleRow(String(localized: "禁用代理"), isOn: $draft.disableProxy)
            labeled(String(localized: "代理设置")) {
                ThemedTextField(placeholder: "socks5://127.0.0.1:10808", text: $draft.proxyURL)
            }
            .opacity(draft.disableProxy ? 0.4 : 1)
            .disabled(draft.disableProxy)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "高级设置"))
            labeled(String(localized: "终端显示编码"), hint: String(localized: "作为 LC_ALL 转发给服务器；非 UTF-8 的最终显示受终端渲染限制")) {
                ThemedDropdown(options: SSHOptions.encodings.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.encoding)
                    .frame(width: 240)
            }
            labeled(String(localized: "主机密钥算法"), hint: String(localized: "一般为空（让 SSH 自动协商）")) {
                ThemedDropdown(options: SSHOptions.hostKeyAlgos.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.hostKeyAlgos)
                    .frame(width: 280)
            }
            labeled(String(localized: "Cipher 算法"), hint: String(localized: "一般为空（让 SSH 自动协商）")) {
                ThemedDropdown(options: SSHOptions.ciphers.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.ciphers)
                    .frame(width: 280)
            }
            labeled(String(localized: "密钥交换算法"), hint: String(localized: "一般为空（让 SSH 自动协商）")) {
                ThemedDropdown(options: SSHOptions.kexAlgos.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.kexAlgos)
                    .frame(width: 320)
            }
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Pal.text)
            .padding(.bottom, 2)
    }

    private func field(_ label: String, placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        labeled(label) { ThemedTextField(placeholder: placeholder, text: text) }
    }

    private func labeled<C: View>(_ label: String, optional: Bool = false, hint: String? = nil, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                if optional {
                    Text("可选").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
            }
            control()
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            ThemedToggle(isOn: isOn)
        }
    }

    private func hintBox(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    Text(line).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var groupSelector: some View {
        labeled(String(localized: "服务器分组")) {
            SearchableSelect(options: model.groupNames, text: $draft.group, placeholder: String(localized: "搜索或新建分组…"))
        }
    }
}
