import AppKit
import SwiftUI

struct AddHostView: View {
    @ObservedObject var model: AppModel
    var editing: Host? = nil
    @StateObject private var draft = HostDraft()
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var section: HostFormSection = .basic
    @State private var showTest = false
    @State private var didLoad = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            HStack(spacing: 0) {
                navSidebar
                Divider().overlay(Pal.fill(0.06))
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider().overlay(Pal.fill(0.06))
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
            } else {
                draft.group = model.groupNames.first ?? ""
            }
        }
        .sheet(isPresented: $showTest) {
            TestConnectionView(draft: draft)
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
                        Text(s.rawValue)
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? Pal.text : Pal.subtext)
                        Spacer()
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
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .background(Pal.solidMantle)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showTest = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 13))
                    Text("测试连接").font(.system(size: 13))
                }
                .foregroundStyle(Pal.mauve)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.mauve.opacity(0.25), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor(draft.canSave)
            .disabled(!draft.canSave)
            .opacity(draft.canSave ? 1 : 0.5)

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
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            draft.keyPath = url.path
        }
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
            sectionTitle("基本信息")
            groupSelector
            field("名称", placeholder: "我的服务器", text: $draft.name)
            HStack(spacing: 12) {
                field("地址", placeholder: "192.168.1.1 或 example.com", text: $draft.address)
                field("端口", placeholder: "22", text: $draft.port).frame(width: 90)
            }
            labeled("验证方式") {
                ThemedDropdown(
                    options: AuthMethod.allCases.map { ($0, $0.rawValue) },
                    selection: $draft.authMethod
                )
                .frame(width: 200)
            }
            field("登录用户", placeholder: "root", text: $draft.user)
            if draft.authMethod == .key {
                labeled("私钥文件") {
                    HStack(spacing: 8) {
                        ThemedTextField(placeholder: "~/.ssh/id_ed25519", text: $draft.keyPath)
                        SecondaryButton(title: "选择…") { chooseKeyFile() }
                    }
                }
                labeled("私钥密码", optional: true) {
                    ThemedSecureField(placeholder: "（私钥有 passphrase 时填写）", text: $draft.password)
                }
            } else {
                labeled("登录密码", optional: true) {
                    ThemedSecureField(placeholder: "（可选）", text: $draft.password)
                }
            }
            labeled("主机备注") {
                ThemedTextEditor(placeholder: "备注信息…", text: $draft.notes)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("连接设置")
            field("超时时间 (ms)", placeholder: "10000", text: $draft.timeout)
            field("心跳时间 (ms)", placeholder: "5000", text: $draft.heartbeat)
        }
    }

    private var initialSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("初始选项")
            field("默认路径", placeholder: "~", text: $draft.defaultPath)
            labeled("初始执行") {
                ThemedTextEditor(placeholder: "#!/bin/bash", text: $draft.initialCommand)
            }
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("代理设置")
            hintBox([
                "选择此选项后，数据将会通过代理进行中转传输。",
                "支持 socks4/socks5 代理，如：socks5://127.0.0.1:10808（鉴权：socks5://user:pass@host:port）",
                "支持 http 代理，如：http://127.0.0.1:10809（鉴权：http://user:pass@host:port）",
                "支持 https 代理，如：https://127.0.0.1:10809（鉴权：https://user:pass@host:port）",
                "若此处留空且在系统设置中开启“使用系统代理”，将自动尝试使用系统代理。",
            ])
            toggleRow("禁用代理", isOn: $draft.disableProxy)
            labeled("代理设置") {
                ThemedTextField(placeholder: "socks5://127.0.0.1:10808", text: $draft.proxyURL)
            }
            .opacity(draft.disableProxy ? 0.4 : 1)
            .disabled(draft.disableProxy)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("高级设置")
            labeled("终端显示编码", hint: "作为 LC_ALL 转发给服务器；非 UTF-8 的最终显示受终端渲染限制") {
                ThemedDropdown(options: SSHOptions.encodings, selection: $draft.encoding)
                    .frame(width: 240)
            }
            labeled("主机密钥算法", hint: "一般为空（让 SSH 自动协商）") {
                ThemedDropdown(options: SSHOptions.hostKeyAlgos, selection: $draft.hostKeyAlgos)
                    .frame(width: 280)
            }
            labeled("Cipher 算法", hint: "一般为空（让 SSH 自动协商）") {
                ThemedDropdown(options: SSHOptions.ciphers, selection: $draft.ciphers)
                    .frame(width: 280)
            }
            labeled("密钥交换算法", hint: "一般为空（让 SSH 自动协商）") {
                ThemedDropdown(options: SSHOptions.kexAlgos, selection: $draft.kexAlgos)
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

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
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
        labeled("服务器分组") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(model.groupNames, id: \.self) { g in
                        chip(g, selected: !draft.creatingGroup && draft.group == g) {
                            draft.creatingGroup = false; draft.group = g
                        }
                    }
                    chip("＋ 新建分组", selected: draft.creatingGroup) {
                        draft.creatingGroup = true
                    }
                    Spacer()
                }
                if draft.creatingGroup {
                    ThemedTextField(placeholder: "新分组名称", text: $draft.newGroup)
                }
            }
        }
    }

    private func chip(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .white : Pal.subtext)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Pal.mauve : Pal.fill(0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
