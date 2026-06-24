import SwiftUI

/// 新增/编辑 RDP（Windows 远程桌面）主机的表单。
/// 独立于 SSH 的 `AddHostView`：字段更聚焦（地址/账号/分辨率/安全级别）。
struct AddRDPHostView: View {
    @ObservedObject var model: AppModel
    var editing: Host? = nil
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var group = ""
    @State private var newGroup = ""
    @State private var creatingGroup = false
    @State private var address = ""
    @State private var port = "3389"
    @State private var user = "Administrator"
    @State private var password = ""
    @State private var domain = ""
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var colorDepth = 32
    @State private var security: RDPSecurity = .auto
    @State private var notes = ""
    @State private var didLoad = false

    private var isEditing: Bool { editing != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var resolvedGroup: String {
        let g = creatingGroup ? newGroup.trimmingCharacters(in: .whitespaces) : group
        return g.isEmpty ? "未分组" : g
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    groupSelector
                    field("名称", "我的 Windows 服务器", $name)
                    HStack(spacing: 12) {
                        field("地址", "192.168.1.10 或 host.example.com", $address)
                        field("端口", "3389", $port).frame(width: 90)
                    }
                    field("登录用户", "Administrator", $user)
                    labeled("登录密码", optional: true) {
                        ThemedSecureField(placeholder: "（可选，保存到系统钥匙串）", text: $password)
                    }
                    labeled("域", optional: true) {
                        ThemedTextField(placeholder: "WORKGROUP / 域名", text: $domain)
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        field("宽", "1920", $width).frame(width: 100)
                        field("高", "1080", $height).frame(width: 100)
                        labeled("色深") {
                            ThemedDropdown(
                                options: [(value: 16, label: "16 位"), (value: 24, label: "24 位"), (value: 32, label: "32 位")],
                                selection: $colorDepth
                            )
                            .frame(width: 110)
                        }
                    }
                    labeled("安全级别", hint: "一般用「自动协商」；Windows 默认启用 NLA") {
                        ThemedDropdown(
                            options: RDPSecurity.allCases.map { ($0, $0.label) },
                            selection: $security
                        )
                        .frame(width: 240)
                    }
                    labeled("主机备注") {
                        ThemedTextEditor(placeholder: "备注信息…", text: $notes)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Pal.fill(0.06))
            footer
        }
        .frame(width: 560, height: 580)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let editing {
                load(from: editing)
            } else {
                group = model.groupNames.first ?? ""
            }
        }
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack {
            Text(isEditing ? "编辑 RDP 主机" : "新增 RDP 主机")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            SecondaryButton(title: "取消") { dismiss() }
            PrimaryButton(title: isEditing ? "保存" : "添加", enabled: canSave) { save() }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - 存取

    private func save() {
        let rdp = buildRDP()
        let n = name.trimmingCharacters(in: .whitespaces)
        let notesT = notes.trimmingCharacters(in: .whitespaces)
        if let editing {
            model.updateRDPHost(id: editing.id, name: n, group: resolvedGroup, notes: notesT, rdp: rdp)
        } else {
            model.addRDPHost(name: n, group: resolvedGroup, notes: notesT, rdp: rdp)
        }
        dismiss()
    }

    private func buildRDP() -> RDPConnection {
        let u = user.trimmingCharacters(in: .whitespaces)
        return RDPConnection(
            user: u.isEmpty ? "Administrator" : u,
            host: address.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 3389,
            password: password,
            domain: domain.trimmingCharacters(in: .whitespaces),
            width: Int(width) ?? 1920,
            height: Int(height) ?? 1080,
            colorDepth: colorDepth,
            security: security
        )
    }

    private func load(from host: Host) {
        name = host.name
        group = host.group
        notes = host.notes
        guard let r = host.rdp else { return }
        address = r.host
        port = String(r.port)
        user = r.user
        password = r.password
        domain = r.domain
        width = String(r.width)
        height = String(r.height)
        colorDepth = r.colorDepth
        security = r.security
    }

    // MARK: - 组件

    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        labeled(label) { ThemedTextField(placeholder: placeholder, text: text) }
    }

    private func labeled<C: View>(_ label: String, optional: Bool = false, hint: String? = nil, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                if optional { Text("可选").font(.system(size: 10)).foregroundStyle(Pal.overlay) }
            }
            control()
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Pal.overlay) }
        }
    }

    private var groupSelector: some View {
        labeled("分组") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(model.groupNames, id: \.self) { g in
                        chip(g, selected: !creatingGroup && group == g) {
                            creatingGroup = false; group = g
                        }
                    }
                    chip("＋ 新建分组", selected: creatingGroup) { creatingGroup = true }
                    Spacer()
                }
                if creatingGroup {
                    ThemedTextField(placeholder: "新分组名称", text: $newGroup)
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
    }
}
