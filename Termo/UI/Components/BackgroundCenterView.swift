import Combine
import SwiftUI

/// 传输任务的强调色（与监控面板上行色一致的 Apple 蓝）；Pal 无内置蓝，故文件内自备。
private let transferBlue = Color(hex: 0x007AFF)

// 删除/清除记录时的「Q 弹」出入场：缩放 + 透明，配合弹簧动画。
private let popTransition: AnyTransition = .scale(scale: 0.82, anchor: .center).combined(with: .opacity)
private let popSpring: Animation = .spring(response: 0.34, dampingFraction: 0.56)

/// 「下载不弹窗」时的一次性飞入动画事件：起点为鼠标位置，终点为左下角后台按钮（其中心由按钮上报）。
struct FlyEvent: Identifiable, Equatable {
    let id: UUID
    let from: CGPoint
}

/// 沿弧线把一个文件图标从 `from` 抛向 `to`（左下角后台按钮），到达时缩小淡出。
/// 一次性：onAppear 启动单段动画，到时回调清空事件——无定时器/轮询，动画结束即销毁，几乎不占 CPU/内存。
struct FlyToCornerView: View {
    let from: CGPoint
    let to: CGPoint
    let onDone: () -> Void
    @State private var progress: CGFloat = 0
    private let duration = 0.62

    var body: some View {
        Image(systemName: "arrow.down.doc.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color(hex: 0x007AFF), in: RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .modifier(ArcFly(progress: progress, from: from, to: to))
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.timingCurve(0.36, 0, 0.2, 1, duration: duration)) { progress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { onDone() }
            }
    }
}

/// 用单一可动画参数 progress(0→1) 驱动二次贝塞尔上抛弧线；末段缩小并淡出。
private struct ArcFly: ViewModifier, Animatable {
    var progress: CGFloat
    let from: CGPoint
    let to: CGPoint
    var animatableData: CGFloat { get { progress } set { progress = newValue } }

    func body(content: Content) -> some View {
        let p = point(progress)
        return content
            .scaleEffect(1 - 0.55 * progress)
            .opacity(progress < 0.8 ? 1 : Double(max(0, (1 - progress) / 0.2)))
            .position(p)
    }

    /// 控制点取两端中点并上抬，形成「上抛后落入」的弧线。
    private func point(_ t: CGFloat) -> CGPoint {
        let lift = max(90, abs(from.y - to.y) * 0.5)
        let ctrl = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - lift)
        let mt = 1 - t
        let x = mt * mt * from.x + 2 * mt * t * ctrl.x + t * t * to.x
        let y = mt * mt * from.y + 2 * mt * t * ctrl.y + t * t * to.y
        return CGPoint(x: x, y: y)
    }
}

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

/// 左下角后台按钮进度环的独立数据源。
///
/// 设计动机：传输任务以 10Hz 采样刷新 overallSent，若把这些高频变更桥接进 AppModel，
/// 会让观察 AppModel 的 ContentView 整树每秒重绘十数次（已在 forwardCancellables 注释中规避）。
/// 故此处单独订阅各传输任务，且仅在「整数百分比」或「有无进度」切换时才 publish，
/// 把刷新频率从 10Hz/任务 压到每个百分点一次，重绘范围也只限进度环本身。
///
/// 进度口径（精密把控）：按字节加权聚合所有「进行中 / 排队 / 暂停」的上传下载，
/// fraction = Σ已传 / Σ总量。排队任务以 0% 计入分母——既未传，又是待办，理应拉低总进度，
/// 如此入队大文件时进度环立即回落，真实反映剩余工作量。
/// 端口转发为常驻无界、解压无逐字节进度，均不计入；无可度量传输时 fraction 为 nil（不画环）。
@MainActor
final class BackgroundProgressModel: ObservableObject {
    @Published private(set) var fraction: Double?

    private let app = AppModel.shared
    private var appSub: AnyCancellable?
    private var taskSubs: [UUID: AnyCancellable] = [:]
    private var lastPercent: Int = -2   // -1 留给「无进度」态，初值取 -2 以触发首发

    init() {
        appSub = app.$transfers.sink { [weak self] tasks in self?.rewire(tasks) }
        rewire(app.transfers)
    }

    /// 传输集合变化（入队/出队/清除）时重建对各任务的订阅。
    private func rewire(_ tasks: [UploadTask]) {
        let ids = Set(tasks.map(\.id))
        taskSubs = taskSubs.filter { ids.contains($0.key) }
        for t in tasks where taskSubs[t.id] == nil {
            // objectWillChange 在变更「前」触发，下一轮 runloop 再读，确保拿到新值。
            taskSubs[t.id] = t.objectWillChange.sink { [weak self] in
                Task { @MainActor in self?.recompute() }
            }
        }
        recompute()
    }

    private func recompute() {
        var total: Int64 = 0, sent: Int64 = 0
        for t in app.transfers where t.phase == .running || t.phase == .paused || t.phase == .queued {
            total += t.totalBytes
            sent += min(t.overallSent, t.totalBytes)
        }
        let f: Double? = total > 0 ? min(1, Double(sent) / Double(total)) : nil
        let pct = f.map { Int($0 * 100) } ?? -1
        guard pct != lastPercent else { return }
        lastPercent = pct
        fraction = f
    }
}

/// 端口转发运行中时叠在图标中心的绿色呼吸点：纯 SwiftUI 自反转动画（缩放 + 透明），无定时器；
/// 视图随 hasRunningForward 出现/消失，转发停止即移除，空闲零开销。
private struct ForwardBreathingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(hex: 0x32D74B))                  // 运行绿
            .frame(width: 3.5, height: 3.5)              // dot 大小
            .scaleEffect(on ? 1.0 : 0.85)
            .opacity(on ? 1.0 : 0.6)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// 活动栏底部的「后台任务」入口按钮：常驻显示，有进行中的任务时带数字角标；点击弹出统一中控面板。
/// 有可度量的传输时，沿按钮圆角边缘绘制一圈细进度环（overlay，不占布局，不改变按钮尺寸）。
struct BackgroundCenterButton: View {
    @ObservedObject var model: AppModel
    @StateObject private var progress = BackgroundProgressModel()
    @State private var open = false
    @State private var hover = false

    private static let side: CGFloat = 38
    private static let ringDiameter: CGFloat = 26   // 进度环直径，小于按钮 38 以贴合图标、不显笨重
    private static let ringWidth: CGFloat = 1.8

    var body: some View {
        // 数字角标只计「非转发」任务（传输/解压）；端口转发为常驻后台，改用图标中心的绿色呼吸点表示。
        let count = model.nonForwardActiveCount
        Button { open.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(open ? Pal.mauve : (hover ? Pal.subtext : Pal.overlay))
                    .frame(width: Self.side, height: Self.side)
                    .background(
                        open ? Pal.mauve.opacity(0.16) : (hover ? Pal.fill(0.08) : Color.clear),
                        in: Circle()
                    )
                    .overlay { progressRing }
                    .overlay { if model.hasRunningForward { ForwardBreathingDot().offset(x: 0, y: 0.25) } }   // 端口转发运行中：中心绿色呼吸点
                    .background(GeometryReader { geo in        // 上报按钮全局中心，作为下载飞入动画的终点
                        Color.clear
                            .onAppear { report(geo) }
                            .onChange(of: geo.frame(in: .global)) { _ in report(geo) }
                    })
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
        .help(String(localized: "后台任务"))
        .popover(isPresented: $open, arrowEdge: .trailing) {
            BackgroundCenterPanel(model: model, dismiss: { open = false })
        }
    }

    private func report(_ geo: GeometryProxy) {
        let f = geo.frame(in: .global)
        model.backgroundButtonCenter = CGPoint(x: f.midX, y: f.midY)
    }

    /// 环绕按钮的圆形进度环：底圈为暗色轨道，进度段为传输蓝、圆头、从正上方顺时针推进。
    @ViewBuilder
    private var progressRing: some View {
        if let p = progress.fraction {
            ZStack {
                Circle().stroke(Pal.fill(0.10), lineWidth: Self.ringWidth)
                Circle()
                    .trim(from: 0, to: max(0.001, p))
                    .stroke(transferBlue, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
            }
            .rotationEffect(.degrees(-90))   // Circle trim 起点在正右，旋转后从正上方起步，符合「时钟」直觉
            .frame(width: Self.ringDiameter, height: Self.ringDiameter)   // 小于按钮，居中贴合图标
            .animation(.linear(duration: 0.18), value: p)
            .transition(.opacity)
            .allowsHitTesting(false)
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
            if model.hasFinishedBackground {
                Button { withAnimation(popSpring) { model.clearFinishedBackground() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 9))
                        Text("清理已完成").font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Pal.subtext)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Pal.fill(0.06), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(String(localized: "清理所有已完成 / 已取消的任务"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    @ViewBuilder
    private var content: some View {
        // 容器恒为 ScrollView：清除最后一条时行仍能完整播放退场动画，空态以 overlay 淡入。
        ScrollView {
            BackgroundActivityList(model: model, dismiss: dismiss)
                .padding(.horizontal, 12).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if model.backgroundActivities.isEmpty {
                emptyState.transition(.opacity)
            }
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

// MARK: - 按主机分组的活动列表（中控面板与退出确认共用）

/// 后台活动列表：按主机分组渲染各任务行。`readOnly` 为真时各行只展示数据、不出操作按钮（用于退出确认）。
struct BackgroundActivityList: View {
    @ObservedObject var model: AppModel
    var readOnly: Bool = false
    var includeFinished: Bool = true   // false=只列进行中（用于退出确认）
    var dismiss: () -> Void = {}

    // 用具名结构而非元组：Swift 不支持指向元组成员的 KeyPath，ForEach(id:) 会编译失败。
    private struct HostGroup: Identifiable {
        let id: String              // hostId 或 "__local__"
        let hostId: String?
        let items: [BackgroundActivity]
    }

    // 按 hostId 分组，保留首次出现顺序；组内进行中的排前、已结束的排后（稳定，保留各自原序）。
    private var groups: [HostGroup] {
        var order: [String] = []
        var map: [String: [BackgroundActivity]] = [:]
        for a in model.backgroundActivities {
            if !includeFinished && a.isFinished { continue }
            let key = a.hostId ?? "__local__"
            if map[key] == nil { order.append(key); map[key] = [] }
            map[key]?.append(a)
        }
        return order.map { key in
            let items = map[key] ?? []
            let sorted = items.filter { !$0.isFinished } + items.filter { $0.isFinished }
            return HostGroup(id: key, hostId: key == "__local__" ? nil : key, items: sorted)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { group in
                groupSection(group.hostId, group.items).transition(popTransition)
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ hostId: String?, _ items: [BackgroundActivity]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            hostHeader(hostId, fallback: items.first?.fallbackHostName ?? "")
            VStack(spacing: 7) {
                ForEach(items) { activity in
                    row(activity).transition(popTransition)
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
        switch activity.payload {
        case .forward(let rule, let manager):
            HubForwardRow(rule: rule, manager: manager, readOnly: readOnly,
                          onToggle: { model.toggleForward(rule) },
                          onManage: {
                              if let h = model.host(rule.hostId) { model.openForwardPanel(h) }
                              dismiss()
                          })
        case .transfer(let task):
            HubTransferRow(task: task, readOnly: readOnly,
                           onOpen: { model.focusedTransferId = task.id; dismiss() },
                           onClear: { withAnimation(popSpring) { model.removeTransfer(task.id) } })
        case .extract(let task):
            HubExtractRow(task: task, readOnly: readOnly,
                          onOpen: { model.showExtractDialog = true; dismiss() },
                          onClear: { withAnimation(popSpring) { model.clearExtract() } })
        }
    }
}

// MARK: - 退出确认弹窗（自定义）

/// 自定义退出确认：
/// - 有后台任务：顶部警告 + 只读任务列表（优先级最高，明确告知会被中断）。
/// - 无任务：简洁的退出确认。
/// 勾选「关闭窗口时隐藏到菜单栏」即开启设置里的同名开关（实时持久化）；勾选后「确定」改为隐藏到托盘而非退出。
struct QuitConfirmDialog: View {
    @ObservedObject var model: AppModel
    var forceMode: Bool = false    // 托盘「退出 Termo」触发：确认即停任务退出，无隐藏选项、不受设置影响
    let onCancel: () -> Void
    let onHideToTray: () -> Void   // 已勾选 → 隐藏到托盘（开关由 checkbox 实时打开）
    let onConfirm: () -> Void       // 未勾选 → 退出
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var theme = ThemeManager.shared

    private var hasTasks: Bool { model.hasRunningBackground }
    // 是否走「隐藏到菜单栏」语义：仅常规模式且已开启设置时；彻底退出模式恒为退出。
    private var hidesOnConfirm: Bool { !forceMode && settings.closeToTray }
    private var confirmTitle: String {
        if forceMode { return hasTasks ? String(localized: "停止任务并退出") : String(localized: "退出") }
        return settings.closeToTray ? String(localized: "确定") : (hasTasks ? String(localized: "关闭任务并退出") : String(localized: "退出"))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(theme.isDark ? 0.42 : 0.20).ignoresSafeArea()
                .onTapGesture(perform: onCancel)
            card
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if hasTasks {
                ScrollView {
                    BackgroundActivityList(model: model, readOnly: true, includeFinished: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            }

            // 勾选即开启设置里的「关闭窗口时隐藏到菜单栏」（实时持久化），后台任务继续运行。
            // 彻底退出模式（托盘「退出 Termo」）不提供隐藏选项——用户已明确选择退出。
            if !forceMode {
                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: settings.closeToTray) { settings.closeToTray.toggle() }
                    Text("关闭窗口时隐藏到菜单栏（后台任务继续运行）")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { settings.closeToTray.toggle() }
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                SecondaryButton(title: "取消", action: onCancel)
                Button {
                    if hidesOnConfirm { onHideToTray() } else { onConfirm() }
                } label: {
                    Text(confirmTitle)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(hidesOnConfirm ? Pal.mauve : Pal.red, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 24, y: 8)
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: hasTasks ? "exclamationmark.triangle.fill" : "power")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hasTasks ? Pal.yellow : Pal.mauve)
                .frame(width: 30, height: 30)
                .background((hasTasks ? Pal.yellow : Pal.mauve).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(hasTasks ? "仍有 \(model.activeBackgroundCount) 个后台任务在运行" : "退出 Termo？")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                Text(hasTasks ? "退出会中断以下任务" : "确认后将关闭应用")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
            Spacer()
        }
    }
}

// MARK: - 行

/// 转发行：观察该主机的 ForwardManager 以实时反映状态；停止 + 跳转完整管理面板。
private struct HubForwardRow: View {
    let rule: ForwardRule
    @ObservedObject var manager: ForwardManager
    var readOnly: Bool = false
    let onToggle: () -> Void
    let onManage: () -> Void

    private var status: ForwardManager.RuleStatus { manager.status(rule.id) }

    var body: some View {
        rowShell(
            icon: "arrow.left.arrow.right", iconColor: Pal.mauve,
            title: rule.name.isEmpty ? rule.kind.title + String(localized: "转发") : rule.name,
            subtitle: rule.summary,
            statusDot: statusColor, statusText: statusText
        ) {
            if !readOnly {
                iconButton("stop.fill", color: Pal.red, help: String(localized: "停止"), action: onToggle)
                iconButton("slider.horizontal.3", color: Pal.subtext, help: String(localized: "管理"), action: onManage)
            }
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
        case .active:   return String(localized: "运行中")
        case .starting: return String(localized: "连接中")
        case .failed(let r): return r
        case .stopped:  return String(localized: "已停止")
        }
    }
}

/// 传输行（上传/下载）：观察 UploadTask 实时进度。
private struct HubTransferRow: View {
    @ObservedObject var task: UploadTask
    var readOnly: Bool = false
    let onOpen: () -> Void
    let onClear: () -> Void

    private var fraction: Double {
        task.totalBytes > 0 ? min(1, Double(task.overallSent) / Double(task.totalBytes)) : 0
    }
    private var verb: String { task.direction == .upload ? String(localized: "上传") : String(localized: "下载") }

    var body: some View {
        rowShell(
            icon: task.direction == .upload ? "arrow.up.circle" : "arrow.down.circle",
            iconColor: transferBlue,
            title: String(localized: "\(verb) \(task.items.count) 项"),
            subtitle: subtitle,
            statusDot: statusColor, statusText: statusText,
            progress: (task.phase == .running || task.phase == .paused) ? fraction : nil,
            subtitleTooltip: task.destDir   // 悬停看完整保存路径（副标题中间截断，不便阅读）
        ) {
            if !readOnly {
                switch task.phase {
                case .running:
                    iconButton("pause.fill", color: Pal.mauve, help: String(localized: "暂停")) { AppModel.shared.pauseTransfer(task) }
                    iconButton("xmark", color: Pal.red, help: String(localized: "取消")) { task.cancel() }
                case .paused:
                    let waiting = task.awaitingSlot
                    iconButton(waiting ? "clock" : "play.fill",
                               color: waiting ? Pal.subtext : Pal.green,
                               help: waiting ? String(localized: "等待名额…") : String(localized: "继续")) { AppModel.shared.resumeTransfer(task) }
                    iconButton("xmark", color: Pal.red, help: String(localized: "取消")) { task.cancel() }
                case .queued:
                    iconButton("xmark", color: Pal.red, help: String(localized: "取消")) { task.cancel() }
                case .done, .cancelled:
                    iconButton("trash", color: Pal.red, help: String(localized: "清除记录"), action: onClear)
                }
                iconButton("arrow.up.left.and.arrow.down.right", color: Pal.subtext, help: String(localized: "展开"), action: onOpen)
            }
        }
    }

    private var subtitle: String {
        if task.phase == .running {
            return "\(Int(fraction * 100))%" + (task.speed > 0 ? " · \(Self.rate(task.speed))" : "")
        }
        if task.phase == .paused { return "\(Int(fraction * 100))%" }
        return task.destDir
    }
    private var statusColor: Color {
        if task.pendingAsk != nil { return Pal.yellow }
        switch task.phase {
        case .queued:    return Pal.overlay
        case .running:   return transferBlue
        case .paused:    return task.awaitingSlot ? Pal.overlay : Pal.yellow
        case .done:      return task.hasFailures ? Pal.yellow : Pal.green
        case .cancelled: return Pal.overlay
        }
    }
    private var statusText: String {
        if task.pendingAsk != nil { return String(localized: "待确认") }
        switch task.phase {
        case .queued:    return String(localized: "排队中")
        case .running:   return task.direction == .upload ? String(localized: "上传中") : String(localized: "下载中")
        case .paused:    return task.awaitingSlot ? String(localized: "等待名额") : String(localized: "已暂停")
        case .done:      return task.hasFailures ? String(localized: "部分失败") : String(localized: "完成")
        case .cancelled: return String(localized: "已取消")
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
    var readOnly: Bool = false
    let onOpen: () -> Void
    let onClear: () -> Void

    // 终态（完成/失败）才可清除；进行中或待解压不可删。
    private var isTerminal: Bool {
        switch task.phase { case .done, .failed: return true; default: return false }
    }

    var body: some View {
        rowShell(
            icon: "doc.zipper", iconColor: Pal.mauve,
            title: String(localized: "解压 \(task.archive.name)"),
            subtitle: task.destDir,
            statusDot: statusColor, statusText: statusText,
            progress: nil,
            subtitleTooltip: task.destDir   // 悬停看完整解压目标路径
        ) {
            if !readOnly {
                if isTerminal {
                    iconButton("trash", color: Pal.red, help: String(localized: "清除记录"), action: onClear)
                }
                iconButton("arrow.up.left.and.arrow.down.right", color: Pal.subtext, help: String(localized: "展开"), action: onOpen)
            }
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
        case .ready:   return String(localized: "待解压")
        case .running: return String(localized: "解压中")
        case .done:    return String(localized: "完成")
        case .failed:  return String(localized: "失败")
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
    subtitleTooltip: String? = nil,
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
                // 状态词让位（英文更长时先截断它）；副标题优先级更高：短的速率/进度完整显示，
                // 长的路径仍按中间截断 + 悬停看全。
                Text(statusText).font(.system(size: 10.5)).foregroundStyle(Pal.subtext)
                    .lineLimit(1).truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.overlay)
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                        .tooltip(subtitleTooltip ?? "", when: subtitleTooltip?.isEmpty == false)
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
