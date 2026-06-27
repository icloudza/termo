import SwiftUI

/// 传输任务的强调色（与监控面板上行色一致的 Apple 蓝）；Pal 无内置蓝，故文件内自备。
private let transferBlue = Color(hex: 0x007AFF)

/// 隐形守卫：上传在后台运行时若需用户确认（同名文件），自动展开上传弹窗，避免静默卡住。
/// 观察 UploadTask 故保持存活；自身不渲染任何可见内容。
struct UploadAskWatcher: View {
    @ObservedObject var task: UploadTask
    let onNeedConfirm: () -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: task.pendingAsk?.id) { id in if id != nil { onNeedConfirm() } }
    }
}

/// 活动栏底部的「后台任务」入口按钮：常驻显示，有进行中的任务时带数字角标；点击弹出统一中控面板。
struct BackgroundCenterButton: View {
    @ObservedObject var model: AppModel
    @State private var open = false
    @State private var hover = false

    var body: some View {
        let count = model.activeBackgroundCount
        Button { open.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(open ? Pal.mauve : (hover ? Pal.subtext : Pal.overlay))
                    .frame(width: 38, height: 38)
                    .background(
                        open ? Pal.mauve.opacity(0.16) : (hover ? Pal.fill(0.08) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                        .background(Pal.mauve, in: Capsule())
                        .overlay(Capsule().stroke(Pal.crust, lineWidth: 1.5))   // 与活动栏底色分离
                        .offset(x: 4, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .help("后台任务")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            BackgroundCenterPanel(model: model, dismiss: { open = false })
        }
    }
}

/// 统一后台任务中控面板：按主机分组列出进行中的端口转发 / 传输 / 解压，可就地管理。
struct BackgroundCenterPanel: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            content
        }
        .frame(width: 360, height: 440)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.mauve)
                .frame(width: 26, height: 26)
                .background(Pal.mauve.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            Text("后台任务").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
            Spacer()
            let n = model.activeBackgroundCount
            if n > 0 {
                Text("\(n) 进行中").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // 一组同主机的后台活动。用具名结构而非元组：Swift 不支持指向元组成员的 KeyPath，ForEach(id:) 会编译失败。
    private struct HostGroup: Identifiable {
        let id: String              // hostId 或 "__local__"
        let hostId: String?
        let items: [BackgroundActivity]
    }

    // 按 hostId 分组，保留首次出现顺序，使同一台机器的任务聚在一起。
    private var groups: [HostGroup] {
        var order: [String] = []
        var map: [String: [BackgroundActivity]] = [:]
        for a in model.backgroundActivities {
            let key = a.hostId ?? "__local__"
            if map[key] == nil { order.append(key); map[key] = [] }
            map[key]?.append(a)
        }
        return order.map { HostGroup(id: $0, hostId: $0 == "__local__" ? nil : $0, items: map[$0] ?? []) }
    }

    @ViewBuilder
    private var content: some View {
        if model.backgroundActivities.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        groupSection(group.hostId, group.items)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 14)
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ hostId: String?, _ items: [BackgroundActivity]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            hostHeader(hostId, fallback: items.first?.fallbackHostName ?? "")
            VStack(spacing: 7) {
                ForEach(items) { activity in
                    row(activity)
                }
            }
        }
    }

    @ViewBuilder
    private func hostHeader(_ hostId: String?, fallback: String) -> some View {
        HStack(spacing: 8) {
            if let id = hostId, let host = model.host(id) {
                HostLeadingIcon(host: host).scaleEffect(0.64).frame(width: 20, height: 20)
                Text(host.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
            } else {
                Image(systemName: "desktopcomputer").font(.system(size: 11)).foregroundStyle(Pal.overlay).frame(width: 20)
                Text(hostId == nil ? "本机" : (fallback.isEmpty ? "未知主机" : fallback))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func row(_ activity: BackgroundActivity) -> some View {
        switch activity {
        case .forward(let rule, let manager):
            HubForwardRow(rule: rule, manager: manager,
                          onToggle: { model.toggleForward(rule) },
                          onManage: {
                              if let h = model.host(rule.hostId) { model.openForwardPanel(h) }
                              dismiss()
                          })
        case .transfer(let task):
            HubTransferRow(task: task, onOpen: { model.showUploadDialog = true; dismiss() })
        case .extract(let task):
            HubExtractRow(task: task, onOpen: { model.showExtractDialog = true; dismiss() })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text("暂无后台任务").font(.system(size: 13)).foregroundStyle(Pal.subtext)
            Text("端口转发、上传下载、解压等会在此统一管理。")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .multilineTextAlignment(.center).frame(maxWidth: 240)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 行

/// 转发行：观察该主机的 ForwardManager 以实时反映状态；停止 + 跳转完整管理面板。
private struct HubForwardRow: View {
    let rule: ForwardRule
    @ObservedObject var manager: ForwardManager
    let onToggle: () -> Void
    let onManage: () -> Void

    private var status: ForwardManager.RuleStatus { manager.status(rule.id) }

    var body: some View {
        rowShell(
            icon: "arrow.left.arrow.right", iconColor: Pal.mauve,
            title: rule.name.isEmpty ? rule.kind.title + "转发" : rule.name,
            subtitle: rule.summary,
            statusDot: statusColor, statusText: statusText
        ) {
            iconButton("stop.fill", color: Pal.red, help: "停止", action: onToggle)
            iconButton("slider.horizontal.3", color: Pal.subtext, help: "管理", action: onManage)
        }
    }

    private var statusColor: Color {
        switch status {
        case .active:   return Pal.green
        case .starting: return Pal.yellow
        case .failed:   return Pal.red
        case .stopped:  return Pal.overlay
        }
    }
    private var statusText: String {
        switch status {
        case .active:   return "运行中"
        case .starting: return "连接中"
        case .failed(let r): return r
        case .stopped:  return "已停止"
        }
    }
}

/// 传输行（上传/下载）：观察 UploadTask 实时进度。
private struct HubTransferRow: View {
    @ObservedObject var task: UploadTask
    let onOpen: () -> Void

    private var fraction: Double {
        task.totalBytes > 0 ? min(1, Double(task.overallSent) / Double(task.totalBytes)) : 0
    }
    private var verb: String { task.direction == .upload ? "上传" : "下载" }

    var body: some View {
        rowShell(
            icon: task.direction == .upload ? "arrow.up.circle" : "arrow.down.circle",
            iconColor: transferBlue,
            title: "\(verb) \(task.items.count) 项",
            subtitle: subtitle,
            statusDot: statusColor, statusText: statusText,
            progress: task.phase == .running ? fraction : nil
        ) {
            if task.phase == .running {
                iconButton("xmark", color: Pal.red, help: "取消") { task.cancel() }
            }
            iconButton("arrow.up.left.and.arrow.down.right", color: Pal.subtext, help: "展开", action: onOpen)
        }
    }

    private var subtitle: String {
        if task.phase == .running {
            return "\(Int(fraction * 100))%" + (task.speed > 0 ? " · \(Self.rate(task.speed))" : "")
        }
        return task.destDir
    }
    private var statusColor: Color {
        if task.pendingAsk != nil { return Pal.yellow }
        switch task.phase {
        case .running:   return transferBlue
        case .done:      return task.hasFailures ? Pal.yellow : Pal.green
        case .cancelled: return Pal.overlay
        }
    }
    private var statusText: String {
        if task.pendingAsk != nil { return "待确认" }
        switch task.phase {
        case .running:   return "\(verb)中"
        case .done:      return task.hasFailures ? "部分失败" : "完成"
        case .cancelled: return "已取消"
        }
    }

    private static func rate(_ bytesPerSec: Double) -> String {
        let u = ["B", "KB", "MB", "GB"]; var v = bytesPerSec; var i = 0
        while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
        let num = String(format: v >= 100 ? "%.0f" : "%.1f", v)
        return "\(num) \(u[i])/s"
    }
}

/// 解压行：观察 ExtractTask 状态（无逐字节进度）。
private struct HubExtractRow: View {
    @ObservedObject var task: ExtractTask
    let onOpen: () -> Void

    var body: some View {
        rowShell(
            icon: "doc.zipper", iconColor: Pal.mauve,
            title: "解压 \(task.archive.name)",
            subtitle: task.destDir,
            statusDot: statusColor, statusText: statusText,
            progress: nil
        ) {
            iconButton("arrow.up.left.and.arrow.down.right", color: Pal.subtext, help: "展开", action: onOpen)
        }
    }

    private var statusColor: Color {
        switch task.phase {
        case .ready:   return Pal.overlay
        case .running: return Pal.mauve
        case .done:    return Pal.green
        case .failed:  return Pal.red
        }
    }
    private var statusText: String {
        switch task.phase {
        case .ready:   return "待解压"
        case .running: return "解压中"
        case .done:    return "完成"
        case .failed:  return "失败"
        }
    }
}

// MARK: - 行外壳（统一视觉）

/// 统一的任务行外壳：左图标 + 标题/副标题(可选进度条) + 状态 + 右侧操作按钮。
@ViewBuilder
private func rowShell<Actions: View>(
    icon: String, iconColor: Color,
    title: String, subtitle: String,
    statusDot: Color, statusText: String,
    progress: Double? = nil,
    @ViewBuilder actions: () -> Actions
) -> some View {
    HStack(spacing: 10) {
        Image(systemName: icon).font(.system(size: 13)).foregroundStyle(iconColor)
            .frame(width: 26, height: 26)
            .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                .lineLimit(1).truncationMode(.middle)
            if let p = progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Pal.fill(0.10)).frame(height: 3)
                        Capsule().fill(statusDot).frame(width: max(2, geo.size.width * p), height: 3)
                    }
                }
                .frame(height: 3)
            }
            HStack(spacing: 5) {
                Circle().fill(statusDot).frame(width: 6, height: 6)
                Text(statusText).font(.system(size: 10.5)).foregroundStyle(Pal.subtext).fixedSize()
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.overlay)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        Spacer(minLength: 6)
        actions()
    }
    .padding(.horizontal, 10).padding(.vertical, 9)
    .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.fill(0.06), lineWidth: 1))
}

/// 行内紧凑图标按钮。
private func iconButton(_ symbol: String, color: Color, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .pointerCursor()
    .help(help)
}
