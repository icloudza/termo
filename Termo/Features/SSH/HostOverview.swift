import SwiftUI

struct HostOverview: View {
    let host: Host
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(host.name).font(.system(size: 20, weight: .medium)).foregroundStyle(Pal.textBright)
                    statusBadge
                    if host.status == .online, let ms = host.latencyMs {
                        let level = LatencyLevel(ms: ms)
                        HStack(spacing: 6) {
                            Text("\(ms) ms").font(.system(size: 12, design: .monospaced)).foregroundStyle(level.color)
                            Text(level.title).font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        }
                    }
                }
                Text("\(host.addr) · 端口 \(host.port)")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .privacyBlur(model.privacyMode)
                    .padding(.top, 6).padding(.bottom, 16)

                specsRow

                HStack(spacing: 10) {
                    action("terminal", "终端", primary: true) { model.openHostTerminal(host) }
                        .contextMenu { Button("新建终端") { model.openHostTerminal(host, forceNew: true) } }
                    action("folder", "文件 (SFTP)", loading: model.openingFilesHostId == host.id) { model.openHostFiles(host) }
                    action("arrow.left.arrow.right", "端口转发", badge: model.hasRunningForward(hostId: host.id)) { model.openForwardPanel(host) }
                    action("pencil", "编辑") { model.beginEditHost(host) }
                }
                .padding(.bottom, 26)

                if !host.notes.isEmpty {
                    Text("备注").font(.system(size: 12)).foregroundStyle(Pal.overlay).padding(.bottom, 8)
                    Text(host.notes)
                        .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 24)
                }

                if host.ssh != nil {
                    if needsAuth {
                        monitorAuthPlaceholder
                    } else {
                        MonitorPanel(monitor: model.hostMonitor(for: liveHost))
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 监控只在概览可见时跑：切到此 tab 开始采集，切走（视图移出）几秒后自动停流，保持轻量。
        .onAppear {
            model.probeHostIfNeeded(liveHost)
            model.overviewAppeared(liveHost)
        }
        // 「每次询问」主机：取得本会话密码后（needsAuth 由 true→false），开始采集。
        .onChange(of: needsAuth) { stillNeeds in
            if !stillNeeds {
                model.probeHostIfNeeded(liveHost)
                model.overviewAppeared(liveHost)
            }
        }
        .onDisappear { model.overviewDisappeared(host.id) }
    }

    /// 实时主机：host 是 Workspace 传入的快照，输密码等变化要从 model 取最新值（HostOverview 已 @ObservedObject model）。
    private var liveHost: Host { model.host(host.id) ?? host }

    /// 「每次询问」且本会话尚未输入密码：监控无法采集，显示占位而非无限「正在建立监控…」。
    private var needsAuth: Bool {
        liveHost.ssh?.authMethod == .ask && (liveHost.ssh?.password ?? "").isEmpty
    }

    private var monitorAuthPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("监控").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                Circle().fill(Pal.overlay).frame(width: 6, height: 6)
            }
            HStack(spacing: 12) {
                Image(systemName: "lock.circle").font(.system(size: 24)).foregroundStyle(Pal.overlay)
                VStack(alignment: .leading, spacing: 3) {
                    Text("连接后开始监控").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    Text("该主机为「每次询问」，输入密码连接成功后，将在本次运行内采集监控数据。")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { model.verifyConnect(host) } label: {
                    Text("连接").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var specsRow: some View {
        if let s = host.specs, !s.isEmpty {
            HStack(spacing: 24) {
                if !s.os.isEmpty { specItem("系统", s.os) }
                if !s.cores.isEmpty { specItem("核心", "\(s.cores) 核") }
                if !s.memory.isEmpty { specItem("内存", s.memory) }
                if !s.disk.isEmpty { specItem("磁盘", s.disk) }
                if !s.vram.isEmpty { specItem("显存", s.vram) }
                if !s.gpu.isEmpty { specItem("显卡", s.gpu) }
            }
            .padding(.bottom, 20)
        } else if model.probingHosts.contains(host.id) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("正在获取系统信息…").font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }
            .padding(.bottom, 20)
        }
    }

    private func specItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
        }
    }

    private var statusBadge: some View {
        let (label, fg, bg): (String, Color, Color) = {
            switch host.status {
            case .online: return ("在线", Pal.green, Pal.green.opacity(0.15))
            case .offline: return ("离线", Pal.overlay, Pal.overlay.opacity(0.15))
            case .unknown: return ("未知", Pal.yellow, Pal.yellow.opacity(0.15))
            }
        }()
        return Text(label).font(.system(size: 11)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func action(_ symbol: String, _ label: String, primary: Bool = false, badge: Bool = false,
                        loading: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 8) {
                Group {
                    if loading {
                        ProgressView().controlSize(.small)   // 连接/指纹预检中：转圈给高延迟主机即时反馈
                    } else {
                        Image(systemName: symbol).font(.system(size: 21))
                            .foregroundStyle(primary ? Pal.mauve : Pal.subtext)
                    }
                }
                .frame(height: 24)   // 固定图标高度，避免不同字形造成卡片高度参差
                Text(loading ? "连接中…" : label).font(.system(size: 12)).foregroundStyle(Pal.text)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                primary ? Pal.mauve.opacity(0.10) : Pal.fill(0.03),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(primary ? Pal.mauve.opacity(0.25) : Pal.fill(0.07), lineWidth: 1)
            )
            // 有进行中的后台任务（如运行中的转发隧道）时，右上角亮一个绿点
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle().fill(Pal.green).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Pal.base, lineWidth: 1.5))
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

}

/// 主机概览的实时监控面板（macOS 原生风格）：CPU 每核热力方块、内存、GPU 卡片阵列、多磁盘、网络与运行时长。
/// 数据来自 [[HostMonitor]] 的流式采样；分区按数据自适应，无 GPU 时隐藏该区，核多则热力方块自动换行。
private struct MonitorPanel: View {
    @ObservedObject var monitor: HostMonitor
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared

    // Apple 系统强调色：蓝（磁盘/上行）、绿（CPU/下行）、紫（GPU/交换）。
    private static let blue = Color(hex: 0x007AFF)
    private static let green = Color(hex: 0x28CD41)
    private static let purple = Color(hex: 0xAF52DE)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 7) {
                Text("监控").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                Circle().fill(monitor.phase == .live ? Self.green : Pal.overlay).frame(width: 6, height: 6)
                if !settings.monitorNoticeHidden && !settings.monitorNoticeAckedThisSession {
                    Text("提示：本监控仅进行数据采集与状态读取，不会在目标机器内执行或部署任何 shell 脚本。")
                        .font(.system(size: 8)).foregroundStyle(Pal.overlay).lineLimit(1)
                    Button { settings.monitorNoticeAckedThisSession = true } label: {
                        Text("我已知晓").font(.system(size: 8, weight: .medium)).foregroundStyle(Pal.mauve)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .tooltip("本次启动内不再显示；如需永久关闭，请在「设置 - 通用」开启「隐藏监控提示」。")
                    Spacer(minLength: 0)
                }
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let m = monitor.metrics {
            cpuSection(m)
            memorySection(m)
            if !m.gpus.isEmpty { gpuSection(m.gpus) }
            if !m.disks.isEmpty { diskSection(m.disks) }
            networkSection(m)
        } else if monitor.phase == .unsupported {
            Text("该系统暂不支持实时监控")
                .font(.system(size: 13)).foregroundStyle(Pal.overlay).padding(.vertical, 6)
        } else {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(monitor.phase == .error ? "监控连接中断，正在重试…" : "正在建立监控…")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: 各区

    private func cpuSection(_ m: HostMetrics) -> some View {
        section("cpu", "处理器核心负载") {
            card {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        num(m.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                            size: 22, weight: .bold, color: Pal.textBright)
                        if !m.perCore.isEmpty {
                            Text("\(m.perCore.count) 核").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        }
                        Spacer()
                        plainNum(String(format: "负载 %.2f / %.2f / %.2f", m.load1, m.load5, m.load15),
                                 size: 10, design: .monospaced, color: Pal.overlay)
                    }
                    if m.perCore.isEmpty {
                        Text("采样中…").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    } else {
                        heatmap(m.perCore)
                    }
                }
            }
        }
    }

    /// 每核占用热力方块：原生方块视图网格，按可用宽度自动换行（每格 10pt、间距 3pt）、自动定高。
    /// 矢量图层、无位图绘制层开销；热力图随采样帧更新颜色，无持续动画。
    private func heatmap(_ cores: [Double]) -> some View {
        let cell: CGFloat = 10, gap: CGFloat = 3
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: gap)],
                         alignment: .leading, spacing: gap) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, load in
                RoundedRectangle(cornerRadius: 2)
                    .fill(heatColor(load))
                    .frame(width: cell, height: cell)
            }
        }
    }

    /// 负载 → 冷暖色：HSB 色相从绿（0.33）过渡到红（0）。
    /// 用 t² 曲线让低/中负载维持沉静绿、暖色集中到高负载，减少中段一片黄绿/橄榄色的浑浊感。
    /// 浅色模式降亮提饱和，得到更深的色，在浅底卡片上保持对比。
    private func heatColor(_ load: Double) -> Color {
        let t = min(1, max(0, load / 100))
        let warm = t * t
        let hue = 0.33 * (1 - warm)
        // 降明度 + 降饱和，得到柔和的雾面色，避免深色模式下高亮绿刺眼。
        return theme.isDark
            ? Color(hue: hue, saturation: 0.58, brightness: 0.76)
            : Color(hue: hue, saturation: 0.78, brightness: 0.66)
    }

    private func memorySection(_ m: HostMetrics) -> some View {
        section("memorychip", "内存") {
            card {
                VStack(spacing: 12) {
                    usageRow(name: "内存", percent: m.memTotalKB > 0 ? m.memPercent : 0,
                             left: "\(human(m.memUsedKB)) / \(human(m.memTotalKB))", right: "RAM", color: Self.blue)
                    if m.hasSwap {
                        usageRow(name: "交换", percent: m.swapPercent,
                                 left: "\(human(m.swapUsedKB)) / \(human(m.swapTotalKB))", right: "SWAP", color: Self.purple)
                    }
                }
            }
        }
    }

    private func diskSection(_ disks: [DiskUsage]) -> some View {
        section("internaldrive", "存储卷") {
            card {
                // 单盘整行（多数服务器只有根分区，半宽会显得空），多盘才用两列紧凑网格。
                if disks.count == 1, let d = disks.first {
                    diskRow(d)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)],
                              alignment: .leading, spacing: 14) {
                        ForEach(disks) { diskRow($0) }
                    }
                }
            }
        }
    }

    private func diskRow(_ d: DiskUsage) -> some View {
        usageRow(name: d.mount, percent: d.percent,
                 left: "\(human(d.usedKB)) / \(human(d.totalKB))",
                 right: d.percent >= 90 ? "CRITICAL" : "DISK", color: Self.blue)
    }

    private func gpuSection(_ gpus: [GPUInfo]) -> some View {
        section("bolt", "图形处理器 (\(gpus.count))") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(gpus) { g in gpuCard(g) }
            }
        }
    }

    private func gpuCard(_ g: GPUInfo) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(g.name).font(.system(size: 9, weight: .medium)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 3))
                    Spacer(minLength: 4)
                    num("\(g.tempC)°", size: 10, weight: .bold, color: Self.purple)
                }
                HStack(alignment: .bottom) {
                    num("\(Int(g.utilPercent))%", size: 17, weight: .bold, color: Pal.textBright)
                    Spacer(minLength: 6)
                    gpuDots(g.utilPercent)
                }
                bar(g.utilPercent, color: Self.purple)
                HStack {
                    Text("显存").font(.system(size: 9)).foregroundStyle(Pal.overlay)
                    Spacer()
                    plainNum("\(gib(g.memUsedMB)) / \(gib(g.memTotalMB)) GB", size: 9, design: .monospaced, color: Pal.overlay)
                }
            }
        }
    }

    /// GPU 迷你点阵：5×2 共 10 颗点，按利用率点亮前 N 颗（紫），其余灰。
    private func gpuDots(_ util: Double) -> some View {
        let lit = Int((min(100, max(0, util)) / 10).rounded())
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(4), spacing: 3), count: 5), spacing: 3) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? Self.purple : Pal.fill(0.16))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: 32)
        .animation(.easeOut(duration: 0.3), value: lit)
    }

    private func networkSection(_ m: HostMetrics) -> some View {
        section("network", "网络") {
            VStack(spacing: 10) {
                card {
                    GeometryReader { geo in
                        // 上下行整体定宽（数字定宽防抖），图表占其余弹性宽度——故图表宽度不随速率文字变化而抖动，
                        // 且窄卡片时由图表先收缩。卡片过窄时上下行改纵向堆叠，避免速率数据溢出卡片右缘。
                        let stacked = geo.size.width < 300
                        HStack(spacing: 12) {
                            NetSparkline(samples: monitor.netHistory, tick: monitor.netTick,
                                         interval: monitor.sampleInterval, down: Self.green, up: Self.blue)
                                .frame(maxWidth: .infinity)
                                .frame(height: geo.size.height)
                            netStats(m, stacked: stacked).fixedSize()
                        }
                    }
                    .frame(height: 36)
                }
                // 运行时长脱离卡片，居中置于网络卡片下方。
                Text(uptimeText(m.uptimeSecs))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// 上下行速率：宽卡片横排、窄卡片纵向堆叠（配合 .fixedSize 整体定宽，杜绝溢出与图表抖动）。
    @ViewBuilder
    private func netStats(_ m: HostMetrics, stacked: Bool) -> some View {
        let down = netStat("arrow.down", rate(m.netRxBytesPerSec), Self.green)
        let up = netStat("arrow.up", rate(m.netTxBytesPerSec), Self.blue)
        if stacked {
            VStack(alignment: .leading, spacing: 3) { down; up }
        } else {
            HStack(spacing: 14) { down; up }
        }
    }

    private func netStat(_ icon: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            // 定宽防止速率位数变化时整体宽度跳动（进而带动弹性图表抖动）。
            num(value, size: 12, weight: .semibold, color: Pal.text)
                .frame(width: 76, alignment: .leading)
        }
    }

    // MARK: 通用组件

    /// 带小节标题（SF 图标 + 静音文字）的区块。
    private func section<C: View>(_ icon: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Pal.overlay)
            content()
        }
    }

    /// macOS 材质卡片。
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.fill(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.fill(0.09), lineWidth: 0.5))
    }

    /// 名称 + 百分比 + 细条 + 用量明细的一行（内存、磁盘共用）。≥90% 转红并显示告警标签。
    private func usageRow(name: String, percent: Double, left: String, right: String, color: Color) -> some View {
        let critical = percent >= 90
        return VStack(spacing: 5) {
            HStack {
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                num("\(Int(percent))%", size: 11, design: .default, color: Pal.subtext)
            }
            bar(percent, color: critical ? Pal.red : color)
            HStack {
                plainNum(left, size: 10, design: .monospaced, color: Pal.overlay)
                Spacer()
                Text(critical ? "CRITICAL" : right)
                    .font(.system(size: 9, weight: critical ? .bold : .regular))
                    .foregroundStyle(critical ? Pal.red : Pal.overlay)
            }
        }
    }

    /// 4px 细进度条。
    private func bar(_ percent: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Pal.fill(0.10))
                Capsule().fill(color)
                    .frame(width: max(0, min(1, percent / 100)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.45), value: percent)
    }

    /// 跳动数字：数值变化时数字像里程表般上滚顶替（contentTransition.numericText），等宽防宽度抖动。
    /// 动画键取显示字符串本身，确保恰在内容变化时触发。
    private func num(_ s: String, size: CGFloat, weight: Font.Weight = .regular,
                     design: Font.Design = .rounded, color: Color) -> some View {
        Text(s)
            .font(.system(size: size, weight: weight, design: design))
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: s)
    }

    /// 次要数字：等宽对齐但不做滚动动画，省去 numericText 的逐字形开销（多个慢变数一起滚很费 CPU）。
    private func plainNum(_ s: String, size: CGFloat, weight: Font.Weight = .regular,
                          design: Font.Design = .rounded, color: Color) -> some View {
        Text(s)
            .font(.system(size: size, weight: weight, design: design))
            .foregroundStyle(color)
            .monospacedDigit()
    }

    // MARK: 格式化

    /// kB（1K 块）按 1000 进制格式化，与概览规格行的单位风格一致。
    private func human(_ kb: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .decimal
        return f.string(fromByteCount: kb * 1024)
    }

    /// 显存 MiB → GiB（1 位小数），与 nvidia-smi 习惯一致。
    private func gib(_ mb: Int64) -> String { String(format: "%.1f", Double(mb) / 1024) }

    private func rate(_ bps: Double?) -> String {
        guard let bps else { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .decimal
        return f.string(fromByteCount: Int64(bps)) + "/s"
    }

    private func uptimeText(_ secs: Double) -> String {
        let s = Int(secs)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "运行 \(d)天 \(h)时 \(m)分" }
        if h > 0 { return "运行 \(h)时 \(m)分" }
        return "运行 \(m) 分"
    }
}

/// 网络波动折线图：下行（绿）、上行（蓝）两条平滑曲线，传送带式匀速左滑。
/// 两条曲线各用原生 Shape（矢量图层）描边 + TimelineView 限制重绘帧率，取代 Canvas 的位图绘制层（更省内存）。
/// 滚动每 1~2 秒才左移约一格、速度极慢，20fps 肉眼丝滑。滚动相位 = 距上一帧采样的时间 / 采样间隔，时间驱动、平滑。
private struct NetSparkline: View {
    let samples: [NetSample]
    let tick: Int
    let interval: Double
    let down: Color
    let up: Color
    @State private var lastTick: Date = .distantPast

    private static let visible = 40
    private static let fps = 20.0
    private static let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)

    var body: some View {
        // rx/tx/maxV 只随数据帧变化，TimelineView 重绘时复用（不每帧重算）。
        let maxV = max(1, samples.flatMap { [$0.rx, $0.tx] }.max() ?? 1)
        let rx = win(samples.map(\.rx), maxV)
        let tx = win(samples.map(\.tx), maxV)
        TimelineView(.animation(minimumInterval: 1.0 / Self.fps)) { tl in
            let phase = phase(at: tl.date)
            ZStack {
                NetCurve(values: rx, phase: phase, visible: Self.visible).stroke(down.opacity(0.9), style: Self.stroke)
                NetCurve(values: tx, phase: phase, visible: Self.visible).stroke(up.opacity(0.9), style: Self.stroke)
            }
            .clipped()   // Shape 不像 Canvas 自动裁，需裁掉两侧的屏外点
        }
        .onChange(of: tick) { _ in lastTick = Date() }
    }

    /// 滚动相位 0..1：距上一帧采样过去的比例；尚无采样时停在 1（静止到位）。
    private func phase(at now: Date) -> CGFloat {
        guard lastTick != .distantPast else { return 1 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(lastTick) / interval)))
    }

    /// 取最近 visible+2 个样本（两侧各留一个屏幕外点）、归一化到 0..1；不足时前端用首值补齐，保证点数恒定、平移无缝。
    private func win(_ raw: [Double], _ maxV: Double) -> [Double] {
        let n = Self.visible + 2
        let norm = raw.map { min(1, max(0, $0 / maxV)) }
        if norm.count >= n { return Array(norm.suffix(n)) }
        return Array(repeating: norm.first ?? 0, count: n - norm.count) + norm
    }
}

/// 一条 Catmull-Rom 平滑折线（已归一化的点，count = visible+2）。
/// 第 i 点画在 x=(i-phase)*step，随 phase 0→1 整条左移一格；两侧各留一个屏外点，接缝 [0,width] 连续、左右缘不弹动。
private struct NetCurve: Shape {
    let values: [Double]
    let phase: CGFloat
    let visible: Int

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        let step = rect.width / CGFloat(visible)
        let pts = values.enumerated().map { i, y in
            CGPoint(x: (CGFloat(i) - phase) * step, y: rect.height * (1 - CGFloat(min(1, max(0, y)))))
        }
        var path = Path()
        path.move(to: pts[0])
        for i in 0..<pts.count - 1 {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
