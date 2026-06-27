import SwiftUI

/// 端口转发管理面板：列出某主机的全部转发规则，可启停、新建、编辑、删除。
/// 隧道复用现有 SSH 凭证、走系统 ssh -L/-R/-D，服务器零安装；运行态由 [[ForwardManager]] 维护。
struct PortForwardView: View {
    @ObservedObject var model: AppModel
    let host: Host
    @ObservedObject private var theme = ThemeManager.shared

    // 非 nil 时进入表单：值为待编辑的规则；新建时为一条该主机的空规则。
    @State private var formRule: ForwardRule? = nil
    @State private var isNew = false
    // 删除确认：非 nil 时弹确认；dontAskAgain 勾选后写入 model.skipForwardDeleteConfirm（仅本次运行）。
    @State private var pendingDelete: ForwardRule? = nil
    @State private var dontAskAgain = false

    private var manager: ForwardManager { model.forwardManager(for: host) }
    private var rules: [ForwardRule] { model.forwardRules(for: host.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            if let rule = formRule {
                ForwardRuleForm(
                    existing: isNew ? nil : rule,
                    hostId: host.id,
                    onSave: { saved in
                        model.saveForwardRule(saved)
                        formRule = nil
                    },
                    onCancel: { formRule = nil }
                )
                .id(rule.id)   // 切换编辑对象时强制重建，避免表单 @State 残留上一条规则
            } else {
                listContent
            }
        }
        .frame(width: 560, height: 520)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .overlay {
            if let rule = pendingDelete {
                deleteConfirm(rule).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: pendingDelete?.id)
    }

    /// 请求删除：本次运行已选「不再询问」则直接删，否则弹确认。
    private func requestDelete(_ rule: ForwardRule) {
        if model.skipForwardDeleteConfirm {
            model.deleteForwardRule(rule)
        } else {
            dontAskAgain = false
            pendingDelete = rule
        }
    }

    /// 删除确认弹窗（含「不再询问」复用设置里的自定义 checkbox；勾选只在本次运行生效）。
    @ViewBuilder
    private func deleteConfirm(_ rule: ForwardRule) -> some View {
        let name = rule.name.isEmpty ? (rule.kind.title + "转发") : rule.name
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { pendingDelete = nil }
            VStack(alignment: .leading, spacing: 14) {
                Text("删除转发规则「\(name)」？")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("将停止其运行中的隧道并移除该规则，不可恢复。")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: dontAskAgain) { dontAskAgain.toggle() }
                    Text("本次不再询问")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { dontAskAgain.toggle() }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消") { pendingDelete = nil }
                    Button {
                        if dontAskAgain { model.skipForwardDeleteConfirm = true }
                        model.deleteForwardRule(rule)
                        pendingDelete = nil
                    } label: {
                        Text("删除").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Pal.red, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Pal.mauve)
                .frame(width: 30, height: 30)
                .background(Pal.mauve.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("端口转发").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text(host.name)
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if formRule == nil {
                Button { startNew() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("新建规则").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Pal.mauve)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            Button { model.forwardPanelHost = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    // MARK: - 规则列表

    @ViewBuilder
    private var listContent: some View {
        if rules.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(rules) { rule in
                        ForwardRow(
                            rule: rule,
                            manager: manager,
                            onToggle: { model.toggleForward(rule) },
                            onEdit: { startEdit(rule) },
                            onDelete: { requestDelete(rule) }
                        )
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 30)).foregroundStyle(Pal.overlay)
            Text("还没有转发规则").font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("通过 SSH 隧道安全访问服务器内网服务，无需在服务器安装任何东西。")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Button { startNew() } label: {
                Text("新建规则").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.mauve)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startNew() {
        formRule = ForwardRule(hostId: host.id)
        isNew = true
    }
    private func startEdit(_ rule: ForwardRule) {
        formRule = rule
        isNew = false
    }
}

/// 单条规则行：状态点 + 摘要 + 启停/编辑/删除。
private struct ForwardRow: View {
    let rule: ForwardRule
    @ObservedObject var manager: ForwardManager
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    private var status: ForwardManager.RuleStatus { manager.status(rule.id) }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(rule.name.isEmpty ? rule.kind.title + "转发" : rule.name)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                    kindBadge
                }
                HStack(spacing: 6) {
                    Text(rule.summary)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.middle)
                    if case .failed(let reason) = status {
                        Text("· \(reason)").font(.system(size: 11)).foregroundStyle(Pal.red).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)

            Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor)

            // 启停
            Button(action: onToggle) {
                Image(systemName: status.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(status.isRunning ? Pal.red : Pal.green)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help(status.isRunning ? "停止" : "启动")

            // 编辑（运行中不可改）
            Button(action: onEdit) {
                Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .disabled(status.isRunning)
            .opacity(status.isRunning ? 0.4 : 1)
            .help(status.isRunning ? "请先停止再编辑" : "编辑")

            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .frame(width: 26, height: 26)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .help("删除")
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(hover ? Pal.fill(0.05) : Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.fill(0.06), lineWidth: 1))
        .animation(.easeOut(duration: 0.12), value: hover)
        .onHover { hover = $0 }
    }

    private var kindBadge: some View {
        Text(rule.kind.title)
            .font(.system(size: 9, weight: .medium)).foregroundStyle(Pal.overlay)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 4))
    }

    private var statusColor: Color {
        switch status {
        case .stopped:  return Pal.overlay
        case .starting: return Pal.yellow
        case .active:   return Pal.green
        case .failed:   return Pal.red
        }
    }
    private var statusText: String {
        switch status {
        case .stopped:  return "已停止"
        case .starting: return "连接中"
        case .active:   return "运行中"
        case .failed:   return "失败"
        }
    }
}

/// 新建/编辑规则表单。
private struct ForwardRuleForm: View {
    let existing: ForwardRule?
    let hostId: String
    let onSave: (ForwardRule) -> Void
    let onCancel: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    @State private var kind: ForwardKind
    @State private var name: String
    @State private var bind: String
    @State private var listen: String
    @State private var destHost: String
    @State private var destPort: String
    @State private var error: String?

    init(existing: ForwardRule?, hostId: String,
         onSave: @escaping (ForwardRule) -> Void, onCancel: @escaping () -> Void) {
        self.existing = existing
        self.hostId = hostId
        self.onSave = onSave
        self.onCancel = onCancel
        let r = existing ?? ForwardRule(hostId: hostId)
        _kind = State(initialValue: r.kind)
        _name = State(initialValue: r.name)
        _bind = State(initialValue: r.bindAddress)
        _listen = State(initialValue: r.listenPort == 0 ? "" : String(r.listenPort))
        _destHost = State(initialValue: r.destHost)
        _destPort = State(initialValue: r.destPort == 0 ? "" : String(r.destPort))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                labeled("类型", hint: kind.hint) {
                    SegmentedControl(
                        options: ForwardKind.allCases.map { ($0, $0.title) },
                        selection: $kind
                    )
                    .frame(width: 240)
                }

                labeled("别名（可选）", hint: "便于识别，如「生产库」。留空则显示类型。") {
                    ThemedTextField(placeholder: "可选", text: $name).frame(maxWidth: 280)
                }

                HStack(alignment: .top, spacing: 16) {
                    labeled("绑定地址", hint: "监听端绑定的网卡地址。仅本机访问填 127.0.0.1；开放给局域网填 0.0.0.0。") {
                        ThemedTextField(placeholder: "127.0.0.1", text: $bind).frame(width: 150)
                    }
                    labeled(kind == .dynamic ? "代理端口" : "监听端口",
                            hint: "在监听端开放的端口，连接它的流量进入隧道。") {
                        ThemedTextField(placeholder: "如 8080", text: $listen).frame(width: 110)
                    }
                }

                if kind != .dynamic {
                    HStack(alignment: .top, spacing: 16) {
                        labeled("目标主机", hint: destHostHint) {
                            ThemedTextField(placeholder: "localhost", text: $destHost).frame(width: 220)
                        }
                        labeled("目标端口", hint: "目标服务监听的端口。") {
                            ThemedTextField(placeholder: "如 3306", text: $destPort).frame(width: 110)
                        }
                    }
                }

                previewLine

                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Pal.red)
                }

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: existing == nil ? "添加" : "保存", action: save)
                }
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destHostHint: String {
        kind == .remote
            ? "从本机视角解析的地址。localhost 指本机自身。"
            : "从服务器视角解析的地址。localhost 指服务器自身——这正是访问只监听内网的远程数据库的用法。"
    }

    // 实时预览将要执行的 ssh 转发参数，帮助理解方向。
    private var previewLine: some View {
        let l = Int(listen) ?? 0
        let dp = Int(destPort) ?? 0
        let b = bind.trimmingCharacters(in: .whitespaces).isEmpty ? "127.0.0.1" : bind
        let preview: String = {
            switch kind {
            case .local:   return "ssh -L \(b):\(l):\(destHost):\(dp)"
            case .remote:  return "ssh -R \(b):\(l):\(destHost):\(dp)"
            case .dynamic: return "ssh -D \(b):\(l)"
            }
        }()
        return VStack(alignment: .leading, spacing: 5) {
            Text("等效命令").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            Text(preview)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.06), lineWidth: 1))
        }
    }

    private func labeled<C: View>(_ title: String, hint: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    .tooltip(hint)
            }
            content()
        }
    }

    private func save() {
        var r = existing ?? ForwardRule(hostId: hostId)
        r.kind = kind
        r.name = name.trimmingCharacters(in: .whitespaces)
        let b = bind.trimmingCharacters(in: .whitespaces)
        r.bindAddress = b.isEmpty ? "127.0.0.1" : b
        r.listenPort = Int(listen.trimmingCharacters(in: .whitespaces)) ?? 0
        r.destHost = destHost.trimmingCharacters(in: .whitespaces)
        r.destPort = Int(destPort.trimmingCharacters(in: .whitespaces)) ?? 0
        if let e = r.validationError { error = e; return }
        onSave(r)
    }
}
