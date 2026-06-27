import AppKit
import Combine
import Darwin
import SwiftTerm
import SwiftUI

/// 首次连接待验证的主机指纹（弹窗用）。respond 回传用户选择。
struct PendingHostKey: Identifiable {
    let id = UUID()
    let info: HostKeyInfo
    let respond: (HostKeyDecision) -> Void
}

// 在线探测的并发队列与上限（最多 6 个并发 TCP 探测，控制线程/CPU，主机多时不会线程爆炸）。
// 置于文件作用域而非 @MainActor 的 AppModel 内：DispatchQueue/Semaphore 本身线程安全且非 actor 隔离，
// 可在后台 Sendable 闭包里直接使用，不触发「主actor隔离静态属性不可在 Sendable 闭包引用」告警。
private let reachQueue = DispatchQueue(label: "termo.reach", attributes: .concurrent)
private let reachLimit = DispatchSemaphore(value: 6)



@MainActor
final class AppModel: ObservableObject {
    @Published var section: Section = .hosts
    @Published var query: String = ""
    // 脱敏显示:开启后隐藏列表/概览里的 IP 与主机名(搜索框旁的眼睛按钮切换)。会话级,不持久化。
    @Published var privacyMode: Bool = false

    // 标签状态独立成 [[TabsModel]]：TabBar/Workspace 只观察它，不被本对象其它 @Published 牵动重算。
    // 下面两个转发计算属性让 AppModel 内部大量 tabs/activeTabId 引用零改动；视图层改为观察 tabsModel。
    let tabsModel = TabsModel()
    var tabs: [TabItem] {
        get { tabsModel.tabs }
        set { tabsModel.tabs = newValue }
    }
    var activeTabId: Int? {
        get { tabsModel.activeTabId }
        set { tabsModel.activeTabId = newValue }
    }
    // 侧栏宽度同样移到独立的 [[LayoutModel]]：拖动改宽度时不再触发本对象的
    // objectWillChange，避免 TabBar/Workspace 等重控件每帧重算（见 LayoutModel 注释）。
    @Published var settingsTab: SettingsTab = .general
    @Published var showSettings = false
    @Published var showAddHost = false
    @Published var editingHost: Host? = nil   // 非 nil 时以编辑模式打开主机表单
    @Published var showAddRDPHost = false
    @Published var editingRDPHost: Host? = nil   // 非 nil 时以编辑模式打开 RDP 主机表单
    @Published var pendingHostKey: PendingHostKey? = nil   // 首次连接待验证的主机指纹
    @Published var connectingHost: Host? = nil   // 正在连接的主机（展示连接进度弹窗）

    // 文件栏右键操作弹窗（删除确认 / 重命名 / 权限 / 刷新冲突 / 信息提示）
    @Published var pendingFileDelete: FileOpContext? = nil
    @Published var pendingFileRename: FileOpContext? = nil
    @Published var pendingFileChmod: ChmodContext? = nil
    @Published var pendingFileCreate: CreateContext? = nil   // 新建文件/文件夹的名称输入弹窗
    @Published var pendingFileRefresh: RefreshConflictContext? = nil
    @Published var pendingFileInfo: FileInfoContext? = nil
    // 上传/下载任务队列：可并发（上限 maxConcurrentTransfers），超出排队。含进行中/排队/已完成（完成后保留待用户清除）。
    @Published var transfers: [UploadTask] = []
    // 当前展开传输弹窗的任务 id（nil=无弹窗）；任务本身在后台继续跑，统一在左下角后台中控管理。
    @Published var focusedTransferId: UUID? = nil
    // 「下载不弹窗」时的飞入动画事件（一次性，动画结束即清空，不常驻、不占用 CPU/内存）。
    @Published var flyTransfer: FlyEvent? = nil
    // 左下角后台任务按钮的全局中心点（由按钮自身上报）；飞入动画的终点。
    var backgroundButtonCenter: CGPoint = .zero
    // 选中文件行的全局矩形（仅选中行上报，按远端路径索引）；飞入动画起点取此处，未命中则回退鼠标位置。
    var fileRowGlobalFrames: [String: CGRect] = [:]
    @Published var extractTask: ExtractTask? = nil // 当前解压任务（nil=无）
    @Published var showExtractDialog = false       // 解压弹窗是否展开；隐藏后任务仍在后台跑，齿轮旁显示迷你状态
    @Published var fileDeleteBusy = false          // 删除进行中：弹窗保留 + 删除键旁转圈，可中途取消
    private var deleteHandle: CommandHandle?        // 取消正在进行的删除（终止远端 rm）
    @Published var pendingBatchDelete: BatchDeleteContext? = nil   // 批量删除确认弹窗
    @Published var batchDeleteBusy = false         // 批量删除进行中：弹窗保留 + 转圈
    @Published var pendingHostDelete: Host? = nil  // 删除主机确认弹窗

    @Published var hosts: [Host] = []
    /// 主机会话历史（终端/上传/端口转发），用于「最近会话」。
    @Published var sessions: [SessionEvent] = []
    /// 全部端口转发规则（持久化）；运行态由 [[ForwardManager]] 单独维护。
    @Published var forwards: [ForwardRule] = []
    /// 非 nil 时展示该主机的端口转发管理面板。
    @Published var forwardPanelHost: Host? = nil
    /// 为真时展示「仍有后台任务」的自定义退出确认弹窗。
    @Published var pendingQuitConfirm = false
    /// 正在 SSH 探测系统信息的主机 id。
    @Published var probingHosts: Set<String> = []

    /// 现有分组（保持出现顺序，去重）
    var groupNames: [String] {
        var seen: [String] = []
        for h in hosts where !seen.contains(h.group) { seen.append(h.group) }
        return seen
    }

    func addHost(from draft: HostDraft) {
        let conn = draft.buildConnection()
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let addr = "\(conn.user)@\(conn.host)"
        let id = "host-\(UUID().uuidString)"
        let newHost = Host(
            id: id,
            name: name,
            addr: addr,
            group: draft.resolvedGroup,
            status: .unknown,
            os: "未知",
            port: conn.port,
            ssh: conn,
            notes: draft.notes.trimmingCharacters(in: .whitespaces)
        )
        hosts.append(newHost)
        HostStore.saveHosts(hosts)
        checkReachability(newHost)
    }

    func beginEditHost(_ host: Host) {
        editingHost = host
    }

    /// 用编辑后的表单覆盖已有主机（保持 id / 状态 / 系统不变）。
    func updateHost(id: String, from draft: HostDraft) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        let conn = draft.buildConnection()
        let old = hosts[idx]
        hosts[idx] = Host(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            addr: "\(conn.user)@\(conn.host)",
            group: draft.resolvedGroup,
            status: old.status,
            os: old.os,
            port: conn.port,
            ssh: conn,
            notes: draft.notes.trimmingCharacters(in: .whitespaces)
        )
        HostStore.saveHosts(hosts)
        checkReachability(hosts[idx])
    }

    /// 新增一台 RDP（Windows 远程桌面）主机。
    func addRDPHost(name: String, group: String, notes: String, rdp: RDPConnection) {
        let id = "host-\(UUID().uuidString)"
        let newHost = Host(
            id: id,
            name: name,
            addr: "\(rdp.user)@\(rdp.host)",
            group: group,
            status: .unknown,
            os: "Windows",
            port: rdp.port,
            ssh: nil,
            notes: notes,
            rdp: rdp
        )
        hosts.append(newHost)
        HostStore.saveHosts(hosts)
        checkReachability(newHost)
    }

    /// 用编辑后的表单覆盖已有 RDP 主机（保持 id / 状态不变）。
    func updateRDPHost(id: String, name: String, group: String, notes: String, rdp: RDPConnection) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        let old = hosts[idx]
        hosts[idx] = Host(
            id: id,
            name: name,
            addr: "\(rdp.user)@\(rdp.host)",
            group: group,
            status: old.status,
            os: old.os,
            port: rdp.port,
            ssh: nil,
            notes: notes,
            rdp: rdp
        )
        HostStore.saveHosts(hosts)
        checkReachability(hosts[idx])
    }

    /// 请求删除主机：按设置决定是否先弹确认弹窗（避免误删），否则直接删除。
    func requestDeleteHost(_ host: Host) {
        if AppSettings.shared.confirmHostDelete {
            pendingHostDelete = host
        } else {
            deleteHost(host.id)
        }
    }
    func confirmHostDelete() {
        if let h = pendingHostDelete { deleteHost(h.id) }
        pendingHostDelete = nil
    }
    func cancelHostDelete() { pendingHostDelete = nil }

    func deleteHost(_ id: String) {
        // 先停掉该主机的转发隧道并清除其规则，避免删除后残留运行中的 ssh -N
        forwardManagers[id]?.stopAll()
        forwardManagers.removeValue(forKey: id)
        forwardCancellables.removeValue(forKey: id)
        if forwards.contains(where: { $0.hostId == id }) {
            forwards.removeAll { $0.hostId == id }
            HostStore.saveForwards(forwards)
        }
        hosts.removeAll { $0.id == id }
        sessions.removeAll { $0.hostId == id }
        HostKeychain.delete(id)
        HostStore.saveHosts(hosts)
        HostStore.saveSessions(sessions)
    }

    // ---------- 会话历史 ----------
    /// 记录一条会话事件并持久化。
    func recordSession(hostId: String, kind: SessionKind, detail: String) {
        sessions.append(SessionEvent(hostId: hostId, kind: kind, detail: detail, timestamp: Date()))
        // 每台主机最多保留 50 条，避免无限增长
        let perHost = Dictionary(grouping: sessions, by: \.hostId)
        var trimmed: [SessionEvent] = []
        for (_, evs) in perHost {
            trimmed += evs.sorted { $0.timestamp > $1.timestamp }.prefix(50)
        }
        sessions = trimmed
        HostStore.saveSessions(sessions)
    }

    /// 某主机最近的会话（倒序，最多 limit 条）。
    func recentSessions(for hostId: String, limit: Int = 6) -> [SessionEvent] {
        sessions
            .filter { $0.hostId == hostId }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    // ---------- 实时监控 ----------
    // 每台「打开中的主机」一份监控，后台持续采样直到该主机全部标签关闭；离开即停、零服务器落地。
    private var hostMonitors: [String: HostMonitor] = [:]
    // 告警去抖：累计连续越界帧数与上次告警时间，键为 "hostId|metric"。
    private var alertStreak: [String: Int] = [:]
    private var alertLast: [String: Date] = [:]

    private static let alertThreshold = 90.0          // 越界阈值（百分比）
    private static let alertSustainFrames = 15         // 连续越界帧数，约 30 秒（2 秒/帧）
    private static let alertCooldown: TimeInterval = 300

    private var monitorStartWork: [String: DispatchWorkItem] = [:]   // 防抖：稳定停留后再启动采集
    private static let monitorDebounce: TimeInterval = 0.4           // 频繁切换主机时，未停留够此时长不启动

    /// 取得（或惰性创建）某主机的监控对象；不在此启动采集——采集只在其概览为当前激活视图时跑（见 overviewAppeared）。
    func hostMonitor(for host: Host) -> HostMonitor {
        if let m = hostMonitors[host.id] { return m }
        let m = HostMonitor(ssh: host.ssh ?? SSHConnection(), simulated: host.isMock)
        let hid = host.id
        m.onSample = { [weak self] metrics in self?.evaluateAlerts(hostId: hid, metrics) }
        hostMonitors[host.id] = m
        return m
    }

    /// 概览成为当前激活视图：防抖后再启动采集。在该时长内切走则启动被取消——飞速切换主机时不会把一堆监控点着，
    /// 任一时刻只有真正停留的那台在跑。
    func overviewAppeared(_ host: Host) {
        monitorStartWork[host.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.monitorStartWork.removeValue(forKey: host.id)
            self?.hostMonitor(for: host).start()   // start 幂等（已在跑则跳过）
        }
        monitorStartWork[host.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.monitorDebounce, execute: work)
    }

    /// 概览不再是当前激活视图：取消待启动并立即冻结该主机监控（停流、保留上次数据快照）。不在后台继续跑。
    func overviewDisappeared(_ hostId: String) {
        monitorStartWork[hostId]?.cancel()
        monitorStartWork.removeValue(forKey: hostId)
        hostMonitors[hostId]?.stop()
    }

    /// 主机已无任何标签时彻底释放其监控对象与告警状态。
    private func stopMonitorIfUnused(_ hostId: String) {
        guard !tabs.contains(where: { $0.hostId == hostId }) else { return }
        monitorStartWork[hostId]?.cancel()
        monitorStartWork.removeValue(forKey: hostId)
        hostMonitors[hostId]?.stop()
        hostMonitors.removeValue(forKey: hostId)
        alertStreak = alertStreak.filter { !$0.key.hasPrefix(hostId + "|") }
        alertLast = alertLast.filter { !$0.key.hasPrefix(hostId + "|") }
    }

    // ---------- 端口转发 ----------
    // 每台主机一份运行态管理器，隧道在后台常驻直到用户停止或退出 App。
    private var forwardManagers: [String: ForwardManager] = [:]
    // 把各管理器的状态变化（启停/失败，低频）桥接到本对象，驱动转发 dot 与后台中控刷新。
    // 转发状态变化稀疏，不会像传输逐帧进度那样引发重绘风暴，故可安全转发 objectWillChange。
    private var forwardCancellables: [String: AnyCancellable] = [:]

    /// 取得（或惰性创建）某主机的端口转发管理器。
    func forwardManager(for host: Host) -> ForwardManager {
        if let m = forwardManagers[host.id] { return m }
        let m = ForwardManager(ssh: host.ssh ?? SSHConnection())
        forwardCancellables[host.id] = m.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        forwardManagers[host.id] = m
        return m
    }

    /// 全部进行中的后台活动（端口转发运行中的隧道 + 当前传输 + 当前解压），供左下角统一中控。
    /// 携带活动对象本身，使中控各行可直接观察其实时状态/进度；分组与命名由视图按 hostId 解析。
    var backgroundActivities: [BackgroundActivity] {
        var out: [BackgroundActivity] = []
        for rule in forwards {
            if let m = forwardManagers[rule.hostId], m.status(rule.id).isRunning {
                out.append(BackgroundActivity(id: "fwd-\(rule.id.uuidString)", hostId: rule.hostId,
                                              fallbackHostName: "", isFinished: false,
                                              payload: .forward(rule: rule, manager: m)))
            }
        }
        for t in transfers {
            let finished = (t.phase == .done || t.phase == .cancelled)
            out.append(BackgroundActivity(id: "xfer-\(t.id.uuidString)", hostId: t.hostId,
                                          fallbackHostName: t.hostName, isFinished: finished,
                                          payload: .transfer(t)))
        }
        if let e = extractTask {
            let finished: Bool = { switch e.phase { case .done, .failed: return true; default: return false } }()
            out.append(BackgroundActivity(id: "ext-\(e.id.uuidString)", hostId: e.hostId,
                                          fallbackHostName: e.hostName, isFinished: finished,
                                          payload: .extract(e)))
        }
        return out
    }

    /// 清除已结束的传输记录（从后台中控移除）。未结束的（进行中/排队/暂停）会先取消。
    func removeTransfer(_ id: UUID) {
        if let t = transfers.first(where: { $0.id == id }),
           t.phase == .running || t.phase == .queued || t.phase == .paused {
            t.cancel()
        }
        transfers.removeAll { $0.id == id }
        if focusedTransferId == id { focusedTransferId = nil }
        pumpTransferQueue()
    }
    /// 清除已结束的解压记录。
    func clearExtract() { extractTask = nil; showExtractDialog = false }

    /// 解压是否处于终态（完成/失败）。
    private var isExtractFinished: Bool {
        guard let e = extractTask else { return false }
        switch e.phase { case .done, .failed: return true; default: return false }
    }
    /// 后台中控里是否有「已完成」的任务可清理（已完成/已取消的传输，或终态的解压）。
    var hasFinishedBackground: Bool {
        transfers.contains { $0.phase == .done || $0.phase == .cancelled } || isExtractFinished
    }
    /// 一键清理所有已结束的后台任务记录（不影响进行中/排队的传输与运行中的转发）。
    func clearFinishedBackground() {
        let removed = Set(transfers.filter { $0.phase == .done || $0.phase == .cancelled }.map { $0.id })
        transfers.removeAll { removed.contains($0.id) }
        if let id = focusedTransferId, removed.contains(id) { focusedTransferId = nil }
        if isExtractFinished { extractTask = nil; showExtractDialog = false }
        pumpTransferQueue()
    }

    /// 进行中的后台活动数（用于中控按钮角标）：运行中的转发 + 进行中/排队的传输 + 进行中的解压。
    var activeBackgroundCount: Int {
        var n = 0
        for rule in forwards where forwardManagers[rule.hostId]?.status(rule.id).isRunning == true { n += 1 }
        n += transfers.filter { $0.phase == .running || $0.phase == .queued || $0.phase == .paused }.count
        if extractTask?.phase == .running { n += 1 }
        return n
    }

    /// 某主机的全部转发规则（按创建顺序）。
    func forwardRules(for hostId: String) -> [ForwardRule] {
        forwards.filter { $0.hostId == hostId }
    }

    /// 某主机是否有运行中的转发隧道（只读，不会惰性创建管理器，可安全在视图 body 中调用）。
    func hasRunningForward(hostId: String) -> Bool {
        guard let m = forwardManagers[hostId] else { return false }
        return forwards.contains { $0.hostId == hostId && m.status($0.id).isRunning }
    }

    /// 打开某主机的端口转发管理面板。
    func openForwardPanel(_ host: Host) { forwardPanelHost = host }

    /// 删除转发规则是否跳过确认：仅本次运行有效（内存态，不持久化）；勾选「不再询问」后本次运行内不再弹窗，
    /// 下次重开 App 仍会提示。故意不放进设置——它是一次性的临时偏好。
    var skipForwardDeleteConfirm = false

    /// 启停一条规则：启动时记一条「端口转发」会话。
    func toggleForward(_ rule: ForwardRule) {
        guard let host = hosts.first(where: { $0.id == rule.hostId }) else { return }
        let m = forwardManager(for: host)
        if m.status(rule.id).isRunning {
            m.stop(rule.id)
        } else {
            m.start(rule)
            recordSession(hostId: host.id, kind: .portForward, detail: rule.summary)
        }
    }

    /// 新增或更新一条规则（按 id 匹配）。
    func saveForwardRule(_ rule: ForwardRule) {
        if let i = forwards.firstIndex(where: { $0.id == rule.id }) { forwards[i] = rule }
        else { forwards.append(rule) }
        HostStore.saveForwards(forwards)
    }

    /// 删除一条规则：先停掉其运行中的隧道，再移除并落盘。
    func deleteForwardRule(_ rule: ForwardRule) {
        if let host = hosts.first(where: { $0.id == rule.hostId }) {
            forwardManager(for: host).stop(rule.id)
        }
        forwards.removeAll { $0.id == rule.id }
        HostStore.saveForwards(forwards)
    }

    /// 逐指标判定阈值告警：持续越界且过冷却期才发一条系统通知。按 id 取最新 host，改名后告警用新名。
    private func evaluateAlerts(hostId: String, _ m: HostMetrics) {
        guard AppSettings.shared.resourceAlerts, let host = hosts.first(where: { $0.id == hostId }) else { return }
        checkAlert(host: host, metric: "cpu", label: "CPU 使用率", value: m.cpuPercent)
        checkAlert(host: host, metric: "mem", label: "内存占用", value: m.memTotalKB > 0 ? m.memPercent : nil)
        checkAlert(host: host, metric: "disk", label: "磁盘占用", value: m.disks.map(\.percent).max())   // 最满的分区
    }

    private func checkAlert(host: Host, metric: String, label: String, value: Double?) {
        let key = host.id + "|" + metric
        guard let v = value, v >= Self.alertThreshold else { alertStreak[key] = 0; return }
        let n = (alertStreak[key] ?? 0) + 1
        alertStreak[key] = n
        guard n >= Self.alertSustainFrames else { return }
        alertStreak[key] = 0   // 重新累计，避免冷却期内反复触发
        let last = alertLast[key] ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.alertCooldown else { return }
        alertLast[key] = Date()
        Notifier.notify(title: "\(host.name) 资源告警",
                        body: "\(label) \(Int(v))%，已持续约 \(Self.alertSustainFrames * 2) 秒")
    }

    /// 构造内置的模拟演示主机：高配 + 双显卡，监控面板用合成数据驱动以预览效果。不连真服务器、不落盘。
    private static func makeMockHost() -> Host {
        var ssh = SSHConnection()
        ssh.host = "mock.demo"; ssh.user = "root"; ssh.port = 22
        var specs = HostSpecs()
        specs.os = "Ubuntu 22.04.5 LTS"
        specs.cores = "64"
        specs.memory = "128 GB"
        specs.disk = "9.2 TB / 12.8 TB"   // 与监控面板三块盘的合计大致一致
        specs.vram = "48 GB"
        specs.gpu = "NVIDIA RTX 5090 ×2"
        specs.probedAt = Date()
        return Host(id: Host.mockHostId, name: "Mock 演示主机", addr: "mock.demo", group: "mock",
                    status: .online, os: "ubuntu", ssh: ssh,
                    notes: "模拟数据，用于预览监控面板效果（不连真服务器）。",
                    specs: specs, latencyMs: 8)
    }

    // ---------- 系统信息探测 ----------
    /// 远端一次性探测脚本：输出多行 key=value。MEM/DISK/VRAM 输出原始字节（客户端再按
    /// 1000 进制统一格式化，避免 free -h/df -h 的 Gi/Mi 单位浮动）；DISK 为「已用 总量」两个字节数；
    /// VRAM/GPU 仅在有 NVIDIA 显卡（nvidia-smi 可用）时非空。
    private static let probeScript = """
    . /etc/os-release 2>/dev/null
    echo "OS=${PRETTY_NAME:-$(uname -sr)}"
    echo "CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
    mem=$(awk '/MemTotal/{printf "%.0f", $2*1024; exit}' /proc/meminfo 2>/dev/null)
    [ -z "$mem" ] && mem=$(sysctl -n hw.memsize 2>/dev/null)
    echo "MEM=$mem"
    echo "DISK=$(df -k / 2>/dev/null | awk 'NR==2{printf "%.0f %.0f", $3*1024, $2*1024}')"
    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END{if(s>0) printf "%.0f", s*1048576}')
    echo "VRAM=$vram"
    echo "GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    """

    /// 系统信息缓存有效期：探测结果(OS/配置/磁盘)在此时间内复用，不重新 SSH 探测。
    private static let specsTTL: TimeInterval = 30 * 60   // 30 分钟

    /// 打开主机概览时调用：后台 SSH 跑一次探测脚本，取真实系统信息并缓存。
    /// 已有未过期的缓存(probedAt 在 specsTTL 内)则跳过——系统信息变化慢，无需每次打开都重探。
    func probeHostIfNeeded(_ host: Host) {
        guard let ssh = host.ssh, !ssh.host.isEmpty, !probingHosts.contains(host.id), !host.isMock else { return }
        if let probedAt = host.specs?.probedAt, Date().timeIntervalSince(probedAt) < Self.specsTTL { return }
        probingHosts.insert(host.id)
        let id = host.id

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = ssh.sshArguments(ephemeralKnownHosts: true) + ["-o", "BatchMode=no", Self.probeScript]
        var env = ProcessInfo.processInfo.environment
        if ssh.needsAskpass, let ap = SSHAskpass.envVars(password: ssh.password) {
            for (k, v) in ap { env[k] = v }
        }
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // 丢弃 stderr
        proc.terminationHandler = { [weak self] _ in
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in self?.applyProbe(id: id, output: text) }
        }

        do {
            try proc.run()
        } catch {
            probingHosts.remove(id)
            return
        }
        // 安全超时：20s 还没结束就杀掉，避免卡在认证
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if proc.isRunning { proc.terminate() }
        }
    }

    private func applyProbe(id: String, output: String) {
        probingHosts.remove(id)
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        var specs = HostSpecs()
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "OS": specs.os = val
            case "CORES": specs.cores = val
            case "MEM": if let b = Int64(val) { specs.memory = Self.fmtBytes(b) }
            case "DISK":
                // "已用字节 总字节" → "53.7 GB / 215 GB"
                let p = val.split(separator: " ")
                if p.count == 2, let u = Int64(p[0]), let t = Int64(p[1]) {
                    specs.disk = "\(Self.fmtBytes(u)) / \(Self.fmtBytes(t))"
                }
            case "VRAM": if let b = Int64(val), b > 0 { specs.vram = Self.fmtBytes(b) }
            case "GPU": specs.gpu = val
            default: break
            }
        }
        guard !specs.isEmpty else { return }   // 探测失败（连接/认证失败）则保留原样
        specs.probedAt = Date()                // 标记探测时间，供 TTL 缓存判定
        hosts[idx].specs = specs
        hosts[idx].status = .online            // 探测成功 ⇒ 一定在线
        HostStore.saveHosts(hosts)
    }

    /// 字节数 → 1000 进制单位（KB/MB/GB/TB）。用十进制（decimal）风格，避免 1024 进制
    /// 的 Gi/Mi 在不同机器/数值间单位浮动，保持展示统一。例：17179869184 → "17.18 GB"。
    private static func fmtBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .decimal
        return f.string(fromByteCount: bytes)
    }

    // ---------- 在线状态检测 ----------
    // 探测并发队列/上限定义在文件级（reachQueue / reachLimit），见文件顶部：
    // 二者本身线程安全，置于文件作用域即非 actor 隔离，可在后台 Sendable 闭包里安全使用，且不触发并发告警。
    private var statusTimer: Timer?

    /// 对所有主机做一次轻量 TCP 可达性检测（启动/刷新/定时调用）。
    func refreshAllStatuses() {
        for host in hosts where !host.isMock { checkReachability(host) }   // 模拟主机不做真实连通探测
    }

    /// 定时扫描在线状态/延迟；仅在 App 处于活动状态时运行（失焦即暂停，省 CPU）。
    private func startStatusTimer() {
        guard statusTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAllStatuses() }
        }
        t.tolerance = 5   // 允许系统合并定时器触发，进一步省电
        statusTimer = t
    }

    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// 轻量在线/延迟探测（不登录）：应用层测真实 RTT，成功=在线+延迟，失败/超时=离线。
    func checkReachability(_ host: Host) {
        let id = host.id
        let isRDP = host.isRDP
        let h: String, p: Int
        if let ssh = host.ssh, !ssh.host.isEmpty {
            h = ssh.host; p = ssh.port
        } else if let rdp = host.rdp, !rdp.host.isEmpty {
            h = rdp.host; p = rdp.port
        } else {
            return
        }
        reachQueue.async { [weak self] in
            reachLimit.wait()
            defer { reachLimit.signal() }
            // RDP 端口无 SSH banner，只做纯 TCP 连通性；SSH 仍走带 1-RTT 测量的探测。
            let (ok, ms) = isRDP ? Self.tcpLatency(host: h, port: p) : Self.sshLatency(host: h, port: p)
            Task { @MainActor in self?.setStatus(id, ok ? .online : .offline, latencyMs: ms) }
        }
    }

    /// 纯 TCP 连通性探测（用于 RDP，没有可读 banner）：连上即在线，握手耗时作粗略延迟。
    private nonisolated static func tcpLatency(host: String, port: Int) -> (Bool, Int?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res, let addr = info.pointee.ai_addr else {
            return (false, nil)
        }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return (false, nil) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let t = DispatchTime.now()
        if connect(fd, addr, info.pointee.ai_addrlen) != 0 {
            if errno != EINPROGRESS { return (false, nil) }
            if !waitFD(fd, POLLOUT, 5) { return (false, nil) }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { return (false, nil) }
        }
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000)
        return (true, ms)
    }

    /// 应用层延迟测量：TCP 连到 SSH 端口判断在线，并在隧道建立后测一次纯 1-RTT。
    /// 纯 TCP/ICMP 握手在 TUN 模式代理下会被本地拦截（显示 ~2ms 假值），
    /// 故改为先收 banner（含代理建隧道开销，丢弃），再发版本、计时收服务器 KEXINIT；
    /// 这次往返穿过代理到真实服务器，反映真实延迟。多采样取首个 ≥3ms 干净值（避开粘包假 0）。
    private nonisolated static func sshLatency(host: String, port: Int) -> (Bool, Int?) {
        var online = false
        var smallSample: Int? = nil
        for _ in 0..<3 {
            let (ok, rtt) = probeOnce(host: host, port: port, timeoutSec: 5)
            if ok { online = true }
            if let rtt {
                if rtt >= 3 { return (true, rtt) }   // 干净样本，直接用
                smallSample = rtt                    // <3ms：疑似粘包，先记下，继续采样
            }
        }
        return (online, online ? smallSample : nil)
    }

    /// 单次探测：连接 → 读 banner → 发版本 → 计时读服务器 KEXINIT。返回 (TCP 是否连通, 纯 RTT 毫秒?)。
    private nonisolated static func probeOnce(host: String, port: Int, timeoutSec: Double) -> (Bool, Int?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res, let addr = info.pointee.ai_addr else {
            return (false, nil)
        }
        defer { freeaddrinfo(res) }

        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        if fd < 0 { return (false, nil) }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // 连接（非阻塞 + poll）
        if connect(fd, addr, info.pointee.ai_addrlen) != 0 {
            if errno != EINPROGRESS { return (false, nil) }
            if !waitFD(fd, POLLOUT, timeoutSec) { return (false, nil) }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            if soErr != 0 { return (false, nil) }
        }
        // TCP 已连通 ⇒ 在线
        var buf = [UInt8](repeating: 0, count: 512)
        // 读 banner（首包，含代理建隧道开销，丢弃）
        if !waitFD(fd, POLLIN, timeoutSec) { return (true, nil) }
        if recv(fd, &buf, buf.count, 0) <= 0 { return (true, nil) }
        // 发我方版本，计时等服务器 KEXINIT（隧道已建立 ⇒ 纯 1 RTT）
        let ver = "SSH-2.0-termo\r\n"
        _ = ver.withCString { send(fd, $0, strlen($0), 0) }
        let t = DispatchTime.now()
        if !waitFD(fd, POLLIN, timeoutSec) { return (true, nil) }
        if recv(fd, &buf, buf.count, 0) <= 0 { return (true, nil) }
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000)
        return (true, ms)
    }

    /// 在 fd 上等待事件（POLLIN/POLLOUT），返回是否就绪（超时/错误返回 false）。
    private nonisolated static func waitFD(_ fd: Int32, _ event: Int32, _ timeoutSec: Double) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(event), revents: 0)
        return poll(&pfd, 1, Int32(timeoutSec * 1000)) > 0
    }

    private func setStatus(_ id: String, _ status: HostStatus, latencyMs: Int? = nil) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        // 运行时状态，不持久化（下次启动重新检测）
        if hosts[idx].status != status { hosts[idx].status = status }
        if hosts[idx].latencyMs != latencyMs { hosts[idx].latencyMs = latencyMs }
    }

    private var terminals: [Int: LocalProcessTerminalView] = [:]
    private var rdpSessions: [Int: RDPSession] = [:]
    private var nextTabId = 1
    private var themeCancellable: AnyCancellable?

    private var settingsCancellable: AnyCancellable?
    private var watchdogTimer: Timer?

    /// 全局单例：托盘与退出流程（AppDelegate）需在窗口之外访问后台任务状态，故让其生命周期独立于窗口。
    static let shared = AppModel()

    private init() {
        // 从磁盘加载主机与会话历史
        hosts = HostStore.loadHosts()
        hosts.append(Self.makeMockHost())   // 注入模拟演示主机（内存中、不落盘），用于预览监控面板
        sessions = HostStore.loadSessions()
        forwards = HostStore.loadForwards()
        HostKeyVerifier.resetSession()   // 清空「仅本次信任」的会话临时 known_hosts
        // 启动即对所有主机做一次轻量在线检测
        defer { refreshAllStatuses() }

        // 用主题配色的视图都已直接 @ObservedObject ThemeManager.shared / AppSettings.shared，
        // 无需再把它们的 objectWillChange 转发到 AppModel（那样会让整棵视图树重复重建）。
        // 这里只订阅副作用：主题/设置变化时刷新各终端的配色与透明度。
        themeCancellable = ThemeManager.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyThemeToTerminals() }
        }
        settingsCancellable = AppSettings.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.applyThemeToTerminals()
                self?.applyTerminalSettings()
                self?.pumpTransferQueue()   // 并发上限可能被调高，立即尝试开跑排队中的传输
            }
        }

        // 网络切换（WiFi 互换、有线无线切换、断网恢复）时立刻重连，不干等 SSH keepalive 超时：
        // 监控即时重连；恢复在线后再重连断开的终端、并重置文件连接使下次操作自动恢复 SFTP。
        NetworkMonitor.shared.onChange = { [weak self] online in
            guard let self else { return }
            for (_, m) in self.hostMonitors { m.handleNetworkChange() }
            for (_, fm) in self.forwardManagers { fm.handleNetworkChange() }
            if online {
                self.reconnectDroppedTerminals()
                self.reconnectFileViewsAfterNetworkChange()
            }
        }

        // 定时扫描在线状态/延迟：App 活动时每 30s 一次，失焦暂停（省 CPU/电）
        startStatusTimer()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startStatusTimer(); self?.refreshAllStatuses() }
        }
        nc.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopStatusTimer() }
        }
        // 退出前掐断所有端口转发隧道：ssh -N 不写 stdout，不会随父进程退出自然终止，必须显式 kill 以免残留。
        // 经线程安全的进程登记表清理，nonisolated 可在退出通知的同步回调里直接调用（不依赖 macOS 14 的 assumeIsolated）。
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ForwardProcessRegistry.shared.terminateAll()
        }

        // 看门狗：每 20s 巡检一次期望保持运行的转发隧道，掉线的补排重启（兜底意外漏掉的退出信号）。
        // 低频且仅在有期望运行隧道时实际动作，开销可忽略；网络抖动的细致处理在 ForwardManager 内。
        let wd = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.forwardWatchdogTick() }
        }
        wd.tolerance = 5
        watchdogTimer = wd
    }

    private func forwardWatchdogTick() {
        for (_, fm) in forwardManagers where fm.hasIntended { fm.watchdogTick() }
    }

    // ---------- 退出/后台任务清理 ----------

    /// 当前进行中的后台任务可读清单（用于退出确认弹窗）：运行中的转发、进行中/排队的传输、进行中的解压。
    var runningBackgroundSummaries: [String] {
        var out: [String] = []
        for rule in forwards where forwardManagers[rule.hostId]?.status(rule.id).isRunning == true {
            let host = hosts.first(where: { $0.id == rule.hostId })?.name ?? "主机"
            out.append("端口转发 · \(host) · \(rule.summary)")
        }
        for t in transfers where t.phase == .running || t.phase == .queued || t.phase == .paused {
            let verb = t.direction == .upload ? "上传" : "下载"
            out.append("\(verb) · \(t.hostName) · \(t.items.count) 项")
        }
        if let e = extractTask, e.phase == .running {
            out.append("解压 · \(e.hostName) · \(e.archive.name)")
        }
        return out
    }

    /// 是否有进行中的后台任务。
    var hasRunningBackground: Bool { !runningBackgroundSummaries.isEmpty }

    /// 退出前停掉所有后台任务：转发隧道、传输、解压。
    func stopAllBackground() {
        for (_, fm) in forwardManagers { fm.stopAll() }
        for t in transfers where t.phase == .running || t.phase == .queued || t.phase == .paused { t.cancel() }
        transfers.removeAll()
        extractTask = nil
    }

    var activeHostId: String? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })?.hostId
    }

    /// 侧栏「文件」面板要显示的树 + 稳定标识 + 所属主机。
    /// 终端/文件标签 → 各自跟随 cwd 的按标签树；编辑器标签 → 主机级资源管理器树（高亮当前文件）。
    var sidebarFileTree: (state: FileTreeState, id: String, host: Host)? {
        guard let id = activeTabId,
              let tab = tabs.first(where: { $0.id == id }),
              let host = host(tab.hostId) else { return nil }
        switch tab.kind {
        case .terminal, .files:
            return (fileTreeState(forTab: id, host: host), "tab-\(id)", host)
        case .editor:
            return (explorerTree(for: host), "host-\(host.id)", host)
        case .overview, .rdp:
            return nil
        }
    }

    func host(_ id: String?) -> Host? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    // ---------- 终端 ----------
    func terminalView(for tabId: Int) -> LocalProcessTerminalView {
        if let tv = terminals[tabId] { return tv }
        let hostId = tabs.first(where: { $0.id == tabId })?.hostId
        let conn = hostId.flatMap { hid in hosts.first(where: { $0.id == hid })?.ssh }
        let tv = makeTerminal(ssh: conn, hostId: hostId, tabId: tabId)
        terminals[tabId] = tv
        return tv
    }

    /// 终端 cwd 变化（OSC 7）→ 定位该标签的侧栏文件树（按标签独立）。
    private var tabCwd: [Int: String] = [:]
    private var termDelegates: [Int: TerminalSessionDelegate] = [:]
    func handleTerminalCwd(tabId: Int, path: String) {
        // 收到 OSC 7 说明登录后提示符已就绪，是最可靠的「已连上」信号：断线态据此即时恢复。
        if let c = terminalConns[tabId], c.phase == .dropped { c.phase = .live; c.attempt = 0 }
        guard tabCwd[tabId] != path else { return }   // 去重：同一目录不重复定位（OSC 7 每次提示符都会发）
        tabCwd[tabId] = path
        fileTreeStates[tabId]?.reveal(path)
    }

    /// SSH 登录后注入的 OSC 7 钩子：bash/zsh 在每次提示符上报当前目录。
    private static let osc7Hook =
        "__t7(){ printf '\\033]7;file://%s%s\\033\\\\' \"${HOSTNAME:-h}\" \"$PWD\"; }; " +
        "if [ -n \"$ZSH_VERSION\" ]; then precmd_functions+=(__t7); " +
        "else PROMPT_COMMAND=\"__t7;${PROMPT_COMMAND}\"; fi; __t7"

    /// 当前终端字体（按设置；空名或找不到则回退到预置等宽字体）。
    private func currentTerminalFont() -> NSFont {
        let size = CGFloat(AppSettings.shared.termFontSize)
        let name = AppSettings.shared.termFont
        if !name.isEmpty, let f = NSFont(name: name, size: size) { return f }
        for n in ["JetBrainsMono Nerd Font", "MesloLGM Nerd Font", "MesloLGS Nerd Font",
                  "Hack Nerd Font", "FiraCode Nerd Font", "FiraCode Nerd Font Mono"] {
            if let f = NSFont(name: n, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 按设置（形状 + 闪烁）得到 SwiftTerm 光标样式。
    private func currentCursorStyle() -> CursorStyle {
        let blink = AppSettings.shared.termCursorBlink
        switch AppSettings.shared.termCursorStyle {
        case "bar": return blink ? .blinkBar : .steadyBar
        case "underline": return blink ? .blinkUnderline : .steadyUnderline
        default: return blink ? .blinkBlock : .steadyBlock
        }
    }

    /// 应用光标样式与滚动缓冲到某终端。
    private func applyTerminalConfig(to tv: LocalProcessTerminalView) {
        let term = tv.getTerminal()
        term.setCursorStyle(currentCursorStyle())
        term.changeScrollback(AppSettings.shared.termScrollback)
    }

    /// 设置变化时刷新所有终端的字体/光标/滚动缓冲。
    private func applyTerminalSettings() {
        let font = currentTerminalFont()
        for tv in terminals.values {
            tv.font = font
            applyTerminalConfig(to: tv)
            tv.setNeedsDisplay(tv.bounds)
        }
    }

    private static func c(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
    }

    // 终端默认 ANSI 调色板
    private static let darkPalette: [SwiftTerm.Color] = [
        c(0x00, 0x00, 0x00), c(0xcd, 0x31, 0x31), c(0x0d, 0xbc, 0x79), c(0xe5, 0xe5, 0x10),
        c(0x24, 0x72, 0xc8), c(0xbc, 0x3f, 0xbc), c(0x11, 0xa8, 0xcd), c(0xe5, 0xe5, 0xe5),
        c(0x66, 0x66, 0x66), c(0xf1, 0x4c, 0x4c), c(0x23, 0xd1, 0x8b), c(0xf5, 0xf5, 0x43),
        c(0x3b, 0x8e, 0xea), c(0xd6, 0x70, 0xd6), c(0x29, 0xb8, 0xdb), c(0xe5, 0xe5, 0xe5),
    ]

    private static let lightPalette: [SwiftTerm.Color] = [
        c(0x00, 0x00, 0x00), c(0xcd, 0x31, 0x31), c(0x00, 0xbc, 0x00), c(0x94, 0x95, 0x00),
        c(0x00, 0x06, 0xc8), c(0xbc, 0x05, 0xbc), c(0x00, 0x98, 0xa8), c(0x55, 0x55, 0x55),
        c(0x66, 0x66, 0x66), c(0xcd, 0x31, 0x31), c(0x14, 0xce, 0x14), c(0xb5, 0xba, 0x00),
        c(0x04, 0x51, 0xa5), c(0xbc, 0x05, 0xbc), c(0x00, 0x98, 0xa8), c(0xa5, 0xa5, 0xa5),
    ]

    private func applyTheme(to tv: LocalProcessTerminalView) {
        let t = ThemeManager.shared.colors
        tv.installColors(ThemeManager.shared.isDark ? Self.darkPalette : Self.lightPalette)
        tv.nativeBackgroundColor = NSColor(hex: t.termBg)
        tv.nativeForegroundColor = NSColor(hex: t.termFg)
        tv.selectedTextBackgroundColor = NSColor(hex: t.termSelection)
        tv.caretColor = NSColor(hex: t.termCaret)
        tv.caretTextColor = NSColor(hex: t.termBg)
    }

    private func applyThemeToTerminals() {
        for tv in terminals.values {
            applyTheme(to: tv)
            // 强制全屏重绘，清掉旧的不透明像素
            tv.getTerminal().updateFullScreen()
            tv.setNeedsDisplay(tv.bounds)
        }
    }

    private func makeTerminal(ssh: SSHConnection? = nil, hostId: String? = nil, tabId: Int) -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        tv.font = currentTerminalFont()
        applyTheme(to: tv)
        applyTerminalConfig(to: tv)

        // 会话代理：cwd 跟踪（仅 SSH 主机）+ 进程退出（exit / 掉线）回调，先于启动设好以免漏掉即时退出
        let d = TerminalSessionDelegate()
        if hostId != nil {   // 仅 SSH 主机跟踪 cwd（用 tabId 定位，无需绑定 hostId 本身）
            d.onCwd = { [weak self] path in
                Task { @MainActor in self?.handleTerminalCwd(tabId: tabId, path: path) }
            }
        }
        d.onTerminated = { [weak self] code in
            Task { @MainActor in self?.handleTerminalExit(tabId: tabId, hostId: hostId, exitCode: code) }
        }
        tv.processDelegate = d
        termDelegates[tabId] = d

        if let ssh {
            startTerminalProcess(tv: tv, ssh: ssh)
            terminalConns[tabId] = TerminalConn()   // 仅 SSH 终端支持断线重连
        } else {
            var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
            if !lang.uppercased().contains("UTF-8") { env.append("LANG=en_US.UTF-8") }
            // 在用户家目录启动（与系统终端一致）；否则会继承 App 进程的工作目录——
            // Xcode 调试时是 .../Build/Products/Debug（提示符里冒出 "Debug"），打包运行时是 "/"。
            tv.startProcess(executable: AppSettings.shared.resolvedShell, args: ["-l"], environment: env,
                            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        }
        return tv
    }

    /// 在给定终端视图上（重新）发起 SSH 连接：构建参数与 askpass 环境、启动 ssh、注入 OSC 7 钩子与初始命令。
    /// 重连复用同一终端视图，滚动历史得以保留。先 terminate 一次：SwiftTerm 的 startProcess 不会清理上一个
    /// 进程的 DispatchIO/childMonitor，重入会泄漏文件描述符；terminate 做有序拆除（且不回调 processTerminated），
    /// 终端缓冲区不受影响。首次连接时进程未启动，terminate 为无害空操作。
    private func startTerminalProcess(tv: LocalProcessTerminalView, ssh: SSHConnection) {
        tv.process.terminate()
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
        if !lang.uppercased().contains("UTF-8") { env.append("LANG=en_US.UTF-8") }
        // 密码用 OpenSSH 内置 SSH_ASKPASS 喂入（无需 sshpass）
        if ssh.needsAskpass, let askpass = SSHAskpass.envVars(password: ssh.password) {
            for (k, v) in askpass { env.append("\(k)=\(v)") }
        }
        tv.startProcess(executable: "/usr/bin/ssh", args: ssh.sshArguments(), environment: env)
        scheduleInitialCommands(tv, ssh: ssh)
    }

    // ---------- 终端断线重连 ----------
    // 仅 SSH 终端：ssh 退出码 255（连接断开）保留标签并自动重连；用户主动 exit 或本地终端按原逻辑关闭。
    private var terminalConns: [Int: TerminalConn] = [:]
    private var terminalReconnectWork: [Int: DispatchWorkItem] = [:]   // 每标签至多一个挂起的重连，防风暴

    /// 视图层取某终端标签的连接态（断线覆盖层观察它）。
    func terminalConn(for tabId: Int) -> TerminalConn? { terminalConns[tabId] }

    func handleTerminalExit(tabId: Int, hostId: String?, exitCode: Int32?) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        // 仅在「SSH 终端 + 连接断开（255）」时保留标签重连。退出码非 255（含用户 exit、被信号杀）一律关闭，
        // 不以离线状态判定，否则离线时主动 exit 会被误当掉线。本地终端无 TerminalConn，落到关闭分支。
        if let hostId, let conn = terminalConns[tabId], exitCode == 255,
           hosts.contains(where: { $0.id == hostId }) {
            conn.dropGen += 1
            conn.phase = .dropped
            scheduleTerminalReconnect(tabId: tabId, hostId: hostId)
            return
        }
        performCloseTab(tabId)
        if let hostId, let host = hosts.first(where: { $0.id == hostId }) {
            let stillUsed = tabs.contains { ($0.kind == .terminal || $0.kind == .files) && $0.hostId == hostId }
            // 传输进行中不关主连接（closeMaster 会掐断复用同一 master 的传输；审查 R20）
            if !stillUsed, !hostHasRunningTransfer(hostId) { RemoteFS(host.ssh ?? SSHConnection()).closeMaster() }
        }
    }

    /// 退避重连：离线时不试（等网络恢复回调触发），在线时按失败次数递增延迟（封顶 15 秒）后重连。
    /// 先撤销该标签已挂起的重连，确保同一时刻只排一个，避免反复掉线时叠加多次并发重连。
    private func scheduleTerminalReconnect(tabId: Int, hostId: String) {
        guard NetworkMonitor.shared.isOnline, let conn = terminalConns[tabId] else { return }
        terminalReconnectWork[tabId]?.cancel()
        let delay = min(15.0, 2.0 * Double(conn.attempt + 1))
        let work = DispatchWorkItem { [weak self] in
            self?.terminalReconnectWork[tabId] = nil
            self?.reconnectTerminal(tabId: tabId, hostId: hostId)
        }
        terminalReconnectWork[tabId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 在原终端视图上重发 SSH 连接。连上判定：OSC 7 的 onCwd 最快置 live；无 OSC 7 的主机由看门狗兜底
    /// ——尝试期间未再掉线（dropGen 未变）即视为已连。
    private func reconnectTerminal(tabId: Int, hostId: String) {
        terminalReconnectWork[tabId]?.cancel()   // 立即重连（手动/网络恢复）撤销可能挂起的退避重连
        terminalReconnectWork[tabId] = nil
        guard let conn = terminalConns[tabId], conn.phase == .dropped,
              tabs.contains(where: { $0.id == tabId }),
              let tv = terminals[tabId],
              let host = hosts.first(where: { $0.id == hostId }), let ssh = host.ssh,
              NetworkMonitor.shared.isOnline else { return }
        conn.attempt += 1
        let gen = conn.dropGen
        startTerminalProcess(tv: tv, ssh: ssh)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, let c = self.terminalConns[tabId],
                  c.phase == .dropped, c.dropGen == gen else { return }
            c.phase = .live
            c.attempt = 0
        }
    }

    /// 网络恢复时立即重连所有断开的终端（清零退避）。先快照，避免重连过程中字典被改动。
    private func reconnectDroppedTerminals() {
        let dropped = terminalConns.filter { $0.value.phase == .dropped }
        for (tabId, conn) in dropped {
            conn.attempt = 0
            if let hostId = tabs.first(where: { $0.id == tabId })?.hostId {
                reconnectTerminal(tabId: tabId, hostId: hostId)
            }
        }
    }

    /// 断线覆盖层「立即重连」按钮。
    func manualReconnectTerminal(_ tabId: Int) {
        guard let conn = terminalConns[tabId], conn.phase == .dropped,
              let hostId = tabs.first(where: { $0.id == tabId })?.hostId else { return }
        conn.attempt = 0
        reconnectTerminal(tabId: tabId, hostId: hostId)
    }

    // ---------- 启动行为 ----------
    private var didApplyStartup = false
    func applyStartupIfNeeded() {
        guard !didApplyStartup else { return }
        didApplyStartup = true
        switch AppSettings.shared.startupBehavior {
        case .terminal:
            openLocalTerminal()
        case .welcome, .restore:
            // 欢迎页为默认（标签为空时即显示）；会话恢复待持久化功能后实现
            break
        }
    }

    private func scheduleInitialCommands(_ tv: LocalProcessTerminalView, ssh: SSHConnection) {
        let path = ssh.defaultPath.trimmingCharacters(in: .whitespaces)
        let cmd = ssh.initialCommand.trimmingCharacters(in: .whitespaces)
        // 总是注入 OSC 7 钩子（用于 cwd 跟踪）；随后清屏隐藏该命令的回显（banner 仍留在 scrollback，
        // 向上滚动可见），再附加可选的 cd / 初始命令（其输出落在清屏后的干净界面上）。
        var tail = ""
        if !path.isEmpty && path != "~" { tail += "cd \(path)" }
        if !cmd.isEmpty { tail += (tail.isEmpty ? "" : " && ") + cmd }
        var line = Self.osc7Hook + "; printf '\\033[2J\\033[H'"
        if !tail.isEmpty { line += "; " + tail }
        line += "\n"
        // 等待 SSH 登录完成后再发送
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak tv] in
            guard let tv else { return }
            tv.send(txt: line)
        }
    }

    // ---------- 标签操作 ----------
    func openLocalTerminal() {
        let title = uniqueTabTitle("终端") { $0.kind == .terminal && $0.hostId == nil }
        addTab(.terminal, title: title, hostId: nil)
    }

    func openHost(_ host: Host) {
        if let existing = tabs.first(where: { $0.kind == .overview && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        addTab(.overview, title: host.name, hostId: host.id)
    }

    func openHostTerminal(_ host: Host) {
        // 立刻显示连接弹窗；指纹验证与真实连接都在弹窗内分步进行（避免海外高延迟主机点击后长时间无反馈）
        connectingHost = host
    }

    /// 连接进度弹窗成功 → 打开真实终端标签。
    func finishConnecting() {
        guard let host = connectingHost else { return }
        connectingHost = nil
        let title = uniqueTabTitle(host.name) { $0.kind == .terminal && $0.hostId == host.id }
        addTab(.terminal, title: title, hostId: host.id)
        recordSession(hostId: host.id, kind: .terminal, detail: "终端会话")
        prewarmExplorer(for: host)
    }

    /// SSH 连上后立刻在后台预建主机资源管理器树，使后续打开文件无可感知的加载。
    func prewarmExplorer(for host: Host) {
        guard host.ssh != nil else { return }
        explorerTree(for: host).startIfNeeded()
    }

    func cancelConnecting() { connectingHost = nil }

    // ---------- RDP 远程桌面 ----------
    /// 打开（或切到）一台 RDP 主机的远程桌面标签。
    func openHostRDP(_ host: Host) {
        guard host.isRDP else { return }
        if let existing = tabs.first(where: { $0.kind == .rdp && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        let id = addTab(.rdp, title: host.name, hostId: host.id)
        rdpSessions[id] = RDPSession(host: host)
        recordSession(hostId: host.id, kind: .rdp, detail: "远程桌面")
    }

    /// 某 RDP 标签的会话状态（缺失则按需创建，保证视图总能拿到）。
    func rdpSession(for tabId: Int, host: Host) -> RDPSession {
        if let s = rdpSessions[tabId] { return s }
        let s = RDPSession(host: host)
        rdpSessions[tabId] = s
        return s
    }

    func openHostFiles(_ host: Host) {
        // 同一主机已有文件标签则切过去
        if let existing = tabs.first(where: { $0.kind == .files && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        Task {
            guard await verifyHostKey(host) else { return }
            addTab(.files, title: host.name, hostId: host.id)
            recordSession(hostId: host.id, kind: .files, detail: "文件浏览")
            prewarmExplorer(for: host)
        }
    }

    /// 首次连接验证主机指纹：已知 → 直接放行；未知 → 弹窗让用户核对后决定。返回是否继续连接。
    func verifyHostKey(_ host: Host) async -> Bool {
        guard let ssh = host.ssh, !ssh.host.isEmpty else { return true }
        let h = ssh.host, p = ssh.port
        let pf = await Task.detached { HostKeyVerifier.preflight(host: h, port: p) }.value
        switch pf {
        case .known, .scanFailed:
            return true   // 已知放行；扫描失败交给 ssh 自己报错
        case .prompt(let info):
            let decision: HostKeyDecision = await withCheckedContinuation { cont in
                pendingHostKey = PendingHostKey(info: info) { cont.resume(returning: $0) }
            }
            pendingHostKey = nil
            switch decision {
            case .cancel: return false
            case .once: HostKeyVerifier.trust(info, persist: false); return true
            case .save: HostKeyVerifier.trust(info, persist: true); return true
            }
        }
    }

    // ---------- 文件浏览状态 ----------
    private var browserStates: [Int: BrowserState] = [:]

    func browserState(for tabId: Int, host: Host) -> BrowserState {
        if let s = browserStates[tabId] { return s }
        let s = BrowserState(fs: RemoteFS(host.ssh ?? SSHConnection()))
        browserStates[tabId] = s
        return s
    }

    /// 侧栏文件树状态（按主机缓存，活动栏「文件」用）。
    // 文件树状态按「标签」分离（同主机的多个会话各自独立）；底层 SSH 连接仍由 ControlMaster 按主机复用。
    private var fileTreeStates: [Int: FileTreeState] = [:]
    func fileTreeState(forTab tabId: Int, host: Host) -> FileTreeState {
        if let s = fileTreeStates[tabId] { return s }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: tabCwd[tabId])
        fileTreeStates[tabId] = s
        return s
    }

    /// 主机级「资源管理器」树（所有编辑器标签共用一棵，高亮跟随当前打开的文件，不随每个文件重载）。
    private var hostExplorerTrees: [String: FileTreeState] = [:]
    func explorerTree(for host: Host) -> FileTreeState {
        if let s = hostExplorerTrees[host.id] { return s }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: nil)
        hostExplorerTrees[host.id] = s
        return s
    }

    /// 网络恢复后重置所有文件视图的底层连接，使下次操作自动重建 SFTP（而非一直降级为 shell）。
    /// 先按主机各清一次 stale ControlMaster（去重，避免多视图重复 ssh -O exit），再重置各视图 SFTP 会话并重载。
    private func reconnectFileViewsAfterNetworkChange() {
        var done = Set<String>()
        for tab in tabs {
            guard let hid = tab.hostId, !done.contains(hid),
                  let ssh = hosts.first(where: { $0.id == hid })?.ssh else { continue }
            done.insert(hid)
            RemoteFS(ssh).closeMaster()
        }
        for (_, b) in browserStates { b.reconnect() }
        for (_, t) in fileTreeStates { t.reconnect() }
        for (_, t) in hostExplorerTrees { t.reconnect() }
    }

    /// 面包屑点击：切到「文件」侧栏并在资源管理器里展开/选中该路径（目录或文件）。
    func jumpToExplorer(path: String, host: Host) {
        section = .files
        revealInExplorer(path, host: host)
    }

    /// 在主机资源管理器树里展开并选中某文件（已存在则原地 reveal，不存在则以该路径初始化）。
    private func revealInExplorer(_ path: String, host: Host) {
        if let tree = hostExplorerTrees[host.id] {
            tree.reveal(path)
        } else {
            hostExplorerTrees[host.id] = FileTreeState(
                fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: path)
        }
    }

    @discardableResult
    private func addTab(_ kind: TabKind, title: String, hostId: String?, filePath: String? = nil) -> Int {
        let id = nextTabId
        nextTabId += 1
        tabs.append(TabItem(id: id, kind: kind, title: title, hostId: hostId, filePath: filePath))
        activeTabId = id
        return id
    }

    // ---------- 文件编辑 / 预览 ----------
    private var editorStates: [Int: EditorState] = [:]
    /// 每个编辑器 tab 的托管视图缓存（NSHostingView 容器）。非 @Published，纯缓存，由 `CachedEditorHost`
    /// 在首次 makeNSView 时填充、关闭 tab 时清理。让编辑器实例脱离 SwiftUI 视图重建、贯穿整个 tab 生命周期存活。
    var editorHosts: [Int: NSView] = [:]

    func editorState(for tabId: Int) -> EditorState? { editorStates[tabId] }

    /// 打开一个远程文件到编辑器/预览标签（同主机同路径已开则切过去）。
    func openFile(_ file: RemoteFile, host: Host) {
        guard !file.isDir else { return }
        revealInExplorer(file.path, host: host)   // 左侧资源管理器高亮到该文件
        if let existing = tabs.first(where: {
            $0.kind == .editor && $0.hostId == host.id && $0.filePath == file.path
        }) {
            activeTabId = existing.id
            return
        }
        let id = addTab(.editor, title: file.name, hostId: host.id, filePath: file.path)
        let st = EditorState(file: file, host: host, fs: RemoteFS(host.ssh ?? SSHConnection()))
        editorStates[id] = st
        st.loadIfNeeded()   // 立刻开始加载（点击即拉取，不等视图出现）
    }

    /// 找到打开了某路径文件的编辑器（用于刷新/重命名时判断是否已打开、是否 dirty）。
    func openEditor(forPath path: String, host: Host) -> EditorState? {
        guard let tab = tabs.first(where: { $0.kind == .editor && $0.hostId == host.id && $0.filePath == path }) else {
            return nil
        }
        return editorStates[tab.id]
    }

    // MARK: - 文件栏右键操作

    /// 刷新：目录 → 重拉（已删则提示并回退上级）；文件 → 若在编辑器打开则刷新内容（dirty 先弹窗确认），
    /// 否则刷新其所在目录（目录内其它已打开/在改的编辑器不受影响，交由其自身的保存冲突机制保护）。
    func fileMenuRefresh(_ file: RemoteFile, host: Host, tree: FileTreeState) {
        Task { @MainActor in
            if file.isDir {
                handleRefreshOutcome(await tree.refreshDir(file.path), name: file.name, isDir: true, tree: tree, path: file.path)
            } else if let ed = openEditor(forPath: file.path, host: host) {
                if ed.isDirty {
                    pendingFileRefresh = RefreshConflictContext(editorState: ed, fileName: file.name)
                } else {
                    ed.reload()
                }
            } else {
                handleRefreshOutcome(await tree.refreshParent(of: file.path), name: file.name, isDir: false, tree: tree, path: file.path)
            }
        }
    }

    func confirmFileRefreshReload() {
        let ed = pendingFileRefresh?.editorState
        pendingFileRefresh = nil
        ed?.reload()
    }

    private func handleRefreshOutcome(_ outcome: FileTreeState.RefreshOutcome, name: String, isDir: Bool, tree: FileTreeState, path: String) {
        switch outcome {
        case .ok:
            break
        case .gone:
            if isDir {
                tree.removeAndSelectParent(path)
                pendingFileInfo = FileInfoContext(title: "目录已被删除",
                    message: "「\(name)」在远端已不存在，已为你移除并定位到上级目录。")
            } else {
                pendingFileInfo = FileInfoContext(title: "目录不存在", message: "该文件所在的目录在远端已不存在。")
            }
        case .failed(let msg):
            pendingFileInfo = FileInfoContext(title: "刷新失败", message: msg)
        }
    }

    // ---------- 传输队列 ----------
    // 并发上限来自设置（上传/下载共用一个池，故二者可同时进行），其余排队；有任务终态时自动补位。
    private var maxConcurrentTransfers: Int { max(1, AppSettings.shared.maxConcurrentTransfers) }

    /// 某主机是否有传输进行中（用于守卫 closeMaster 不掐断复用同一 master 的传输，审查 R20）。
    func hostHasRunningTransfer(_ hostId: String) -> Bool {
        transfers.contains { $0.hostId == hostId && $0.phase == .running }
    }

    /// 入队一个新传输：加入列表、自动展开其弹窗，并尝试按并发上限启动。
    private func enqueueTransfer(_ task: UploadTask) {
        task.onFinished = { [weak self] in self?.transferDidFinish() }
        task.onPauseStateChanged = { [weak self] in self?.pumpTransferQueue() }
        // 逐文件互斥锁：仅当两任务真要写同一目标文件时才串行，按字节冲突而非整任务冲突，杜绝空占名额。
        task.acquirePathLock = { [weak self] key in
            guard let self else { return }
            await self.acquireTransferPath(key)
        }
        task.releasePathLock = { [weak self] key in
            guard let self else { return }
            self.releaseTransferPath(key)
        }
        transfers.append(task)
        // 下载且设置为「不弹窗」时：不展开弹窗，改放飞入左下角的弧线动画；其余情况照常自动展开。
        if task.direction == .download && !AppSettings.shared.showDownloadDialog {
            triggerDownloadFly(for: task)
        } else {
            focusedTransferId = task.id   // 自动展开新任务弹窗（保持单任务时的体验）
        }
        pumpTransferQueue()
    }

    /// 触发一次「下载飞入左下角后台任务」的弧线动画。
    /// 起点优先取所选文件行的位置（首个文件），未命中则回退鼠标位置、再回退默认偏移；终点为后台按钮中心。
    /// 全部坐标统一在 SwiftUI 全局空间，叠层渲染时再按叠层自身原点换算（见 ContentView），故各窗口尺寸都对得上。
    /// 事件一次性，动画结束由视图清空，不常驻、不占 CPU/内存。
    private func triggerDownloadFly(for task: UploadTask) {
        guard backgroundButtonCenter != .zero else { return }
        let from: CGPoint
        if let p = task.items.first?.remotePath, let r = fileRowGlobalFrames[p] {
            from = CGPoint(x: r.midX, y: r.midY)            // 所选文件行中心
        } else if let m = Self.currentMouseGlobal() {
            from = m                                        // 右键下载时鼠标即在该文件上
        } else {
            from = CGPoint(x: backgroundButtonCenter.x + 220, y: backgroundButtonCenter.y - 220)
        }
        flyTransfer = FlyEvent(id: UUID(), from: from)
    }

    /// 鼠标当前位置，转换到 SwiftUI 全局坐标（左上原点），用于动画起点。
    private static func currentMouseGlobal() -> CGPoint? {
        guard let win = NSApp.keyWindow ?? NSApp.mainWindow, let cv = win.contentView else { return nil }
        let p = cv.convert(win.mouseLocationOutsideOfEventStream, from: nil)   // contentView 坐标，左下原点
        return CGPoint(x: p.x, y: cv.bounds.height - p.y)                      // 翻转为左上原点
    }

    // 逐文件目标互斥（全在 MainActor 上，故 Set/字典无数据竞争）：
    // 旧实现按「整任务文件集」在调度期去冲突，会让与某长任务有任一同名文件的排队任务整段被跳过、白占空名额。
    // 改为运行期按单个目标文件加锁：所有排队任务照常并发开跑，只有真正同时写同一文件时才让后者短暂等待。
    private var lockedTransferPaths: Set<String> = []
    private var transferPathWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// 获取某目标文件的写锁；已被占用则挂起，待持有者释放后重新竞争（释放会唤醒全部等待者，由其各自重判）。
    func acquireTransferPath(_ key: String) async {
        while lockedTransferPaths.contains(key) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                transferPathWaiters[key, default: []].append(c)
            }
        }
        lockedTransferPaths.insert(key)
    }
    /// 释放写锁并唤醒所有等待该文件的任务（其中一个会抢到，其余重新挂起）。
    func releaseTransferPath(_ key: String) {
        lockedTransferPaths.remove(key)
        let waiters = transferPathWaiters.removeValue(forKey: key) ?? []
        for w in waiters { w.resume() }
    }

    /// 暂停一个传输：释放/保留名额由设置 pausedReleasesSlot 决定，名额变化经 onPauseStateChanged 触发 pump。
    func pauseTransfer(_ task: UploadTask) { task.pause() }

    /// 恢复一个传输：按当前名额占用判断能否立即续传，否则标记等待、由 pump 在名额释放时放行。
    func resumeTransfer(_ task: UploadTask) {
        guard task.phase == .paused else { return }
        if !AppSettings.shared.pausedReleasesSlot {
            // 预留名额模式：该任务名额一直占着，直接续传即可，不会超出上限。
            task.requestResume(slotFree: true)
        } else {
            task.requestResume(slotFree: transferSlotsOccupied() < maxConcurrentTransfers)
        }
        pumpTransferQueue()
    }

    /// 当前占用的并发名额数：运行中恒计入；暂停态仅在「预留名额」模式下计入。
    private func transferSlotsOccupied() -> Int {
        let running = transfers.filter { $0.phase == .running }.count
        if AppSettings.shared.pausedReleasesSlot { return running }
        return running + transfers.filter { $0.phase == .paused }.count
    }

    /// 按并发上限推进队列：先放行「等待名额」的恢复请求，再启动排队中的新任务，直至占满空位。
    /// 同名目标文件的串行交由运行期逐文件写锁处理（acquireTransferPath），故此处只看名额、不再整任务去冲突，
    /// 不会因某长任务占着同名文件而让排队任务空等名额。
    private func pumpTransferQueue() {
        let cap = maxConcurrentTransfers
        // 释放名额模式下，用户已点恢复但当时无空位的任务优先补位（它们已在传输中途，先于全新任务）。
        if AppSettings.shared.pausedReleasesSlot {
            for task in transfers where task.phase == .paused && task.awaitingSlot {
                guard transferSlotsOccupied() < cap else { break }
                task.admitResume()   // 同步置为 .running，故 transferSlotsOccupied() 立即反映
            }
        }
        for task in transfers where task.phase == .queued {
            guard transferSlotsOccupied() < cap else { break }
            task.start()   // start() 同步把任务置为 .running，故同一轮内后续任务的名额判断能看到它
        }
    }

    /// 某传输进入终态：补位下一个排队任务，并刷新角标/中控的进行中计数（终态变化不改 transfers 数组本身）。
    private func transferDidFinish() {
        pumpTransferQueue()
        objectWillChange.send()
    }

    /// 上传文件到某文件夹：弹系统选择器（可多选文件），逐个上传，支持续传/压缩/同名询问。
    func beginUpload(into folder: RemoteFile, host: Host) {
        guard folder.isDir else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.message = "选择要上传到「\(folder.name)」的文件"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        startUpload(files: panel.urls, destDir: folder.path, host: host)
    }

    /// 外部文件拖入终端：上传到该终端的当前目录（OSC7 跟踪的 cwd；未知则取远端家目录）。仅 SSH 终端。
    func uploadDroppedFiles(_ urls: [URL], toTabId tabId: Int) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let host = host(tab.hostId), let ssh = host.ssh, !ssh.host.isEmpty else { return }
        // 只传文件，跳过目录
        let files = urls.filter { !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
        guard !files.isEmpty else {
            pendingFileInfo = FileInfoContext(title: "无法上传", message: "暂不支持拖拽文件夹，请拖入文件。")
            return
        }
        Task { @MainActor in
            let cwd: String
            if let known = tabCwd[tabId] { cwd = known } else { cwd = await RemoteFS(ssh).home() }
            startUpload(files: files, destDir: cwd, host: host)
        }
    }

    /// 拖拽上传：把外部拖入的文件上传到指定远端目录（SFTP 浏览器拖放用）。只传文件，跳过文件夹。
    func uploadFiles(_ urls: [URL], toDir dir: String, host: Host) {
        guard let ssh = host.ssh, !ssh.host.isEmpty, !dir.isEmpty else { return }
        let files = urls.filter { !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
        guard !files.isEmpty else {
            pendingFileInfo = FileInfoContext(title: "无法上传", message: "暂不支持拖拽文件夹，请拖入文件。")
            return
        }
        startUpload(files: files, destDir: dir, host: host)
    }

    /// 启动上传任务（核心）：入队后按并发上限自动开始；落地后局部刷新相关文件树缓存。
    private func startUpload(files: [URL], destDir: String, host: Host) {
        guard !files.isEmpty else { return }
        let task = UploadTask(files: files, destDir: destDir,
                              fs: RemoteFS(host.ssh ?? SSHConnection())) { [weak self] in
            self?.refreshTrees(host: host, dir: destDir)
        }
        task.hostId = host.id
        task.hostName = host.name
        enqueueTransfer(task)
    }

    /// 文件变更后（上传落地 / 解压完成）：只**局部**刷新该主机各缓存文件树/浏览器里「指定目录」这一层——
    /// 重列该目录、保留其余展开，不全量重载；树中未加载该目录的直接跳过（node 查找命中失败即返回，无网络开销）。
    private func refreshTrees(host: Host, dir: String) {
        Task { @MainActor in
            if let t = hostExplorerTrees[host.id] { _ = await t.refreshDir(dir) }   // 编辑器侧栏共用的主机级树
            for (tabId, t) in fileTreeStates where tabHostId(tabId) == host.id {     // 各会话 tab 的文件树
                _ = await t.refreshDir(dir)
            }
            for (tabId, b) in browserStates where tabHostId(tabId) == host.id && b.path == dir {  // 正展示该目录的 SFTP 浏览器
                b.reload()
            }
        }
    }

    private func tabHostId(_ tabId: Int) -> String? {
        tabs.first(where: { $0.id == tabId })?.hostId
    }

    func fileMenuRequestDelete(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        pendingFileDelete = FileOpContext(file: file, host: host, target: target)
    }

    /// 确认删除：弹窗保留并进入「删除中」（删除键旁转圈），过程可经 cancelFileDelete 中途取消。
    /// 删除可能较慢（大目录 rm -rf），故不立刻关弹窗——成功后才关，失败弹错误，取消后刷新真实状态。
    func confirmFileDelete() {
        guard let ctx = pendingFileDelete, !fileDeleteBusy else { return }
        fileDeleteBusy = true
        let handle = CommandHandle()
        deleteHandle = handle
        let host = ctx.host
        let parent = (ctx.file.path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? "/" : parent
        Task { @MainActor in
            let r = await ctx.target.performDelete(ctx.file, handle: handle)
            deleteHandle = nil
            fileDeleteBusy = false
            if handle.isCancelled {
                refreshTrees(host: host, dir: dir)   // 取消可能已部分删除，刷新反映真实状态
                return
            }
            pendingFileDelete = nil
            if case .failure(let e) = r {
                pendingFileInfo = FileInfoContext(title: "删除失败", message: e.message)
            }
        }
    }

    /// 取消删除：删除进行中则终止远端命令（收尾与刷新交给删除任务的完成回调），随后关闭弹窗。
    func cancelFileDelete() {
        if fileDeleteBusy { deleteHandle?.cancel() }
        pendingFileDelete = nil
    }

    // MARK: - 批量删除

    func requestBatchDelete(_ files: [RemoteFile], host: Host, target: any FileOpsTarget) {
        guard !files.isEmpty else { return }
        pendingBatchDelete = BatchDeleteContext(files: files, host: host, target: target)
    }

    /// 确认批量删除：逐个删除（弹窗保留 + 转圈），完成后关弹窗；任一失败弹错误提示。
    func confirmBatchDelete() {
        guard let ctx = pendingBatchDelete, !batchDeleteBusy else { return }
        batchDeleteBusy = true
        Task { @MainActor in
            var failed: [String] = []
            for f in ctx.files {
                if case .failure = await ctx.target.performDelete(f, handle: nil) { failed.append(f.name) }
            }
            batchDeleteBusy = false
            pendingBatchDelete = nil
            if !failed.isEmpty {
                let shown = failed.prefix(8).joined(separator: "、")
                pendingFileInfo = FileInfoContext(title: "部分删除失败",
                                                  message: "未能删除：\(shown)\(failed.count > 8 ? " 等" : "")")
            }
        }
    }

    func cancelBatchDelete() { if !batchDeleteBusy { pendingBatchDelete = nil } }

    func fileMenuRequestRename(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        pendingFileRename = FileOpContext(file: file, host: host, target: target)
    }

    func confirmFileRename(newName: String) {
        guard let ctx = pendingFileRename else { return }
        pendingFileRename = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            pendingFileInfo = FileInfoContext(title: "名称无效", message: "名称不能为空或包含「/」。")
            return
        }
        if trimmed == ctx.file.name { return }
        let oldPath = ctx.file.path
        Task { @MainActor in
            switch await ctx.target.performRename(ctx.file, newName: trimmed) {
            case .success(let newPath):
                syncRenamedEditorTab(oldPath: oldPath, newName: trimmed, newPath: newPath,
                                     kind: ctx.file.kind, size: ctx.file.size, modified: ctx.file.modified,
                                     host: ctx.host)
            case .failure(let e):
                pendingFileInfo = FileInfoContext(title: "重命名失败", message: e.message)
            }
        }
    }

    /// 重命名成功后同步「已打开该文件的编辑器标签」：未保存改动时不动并提示，否则更新标签标题/路径与编辑器的保存目标。
    private func syncRenamedEditorTab(oldPath: String, newName: String, newPath: String,
                                      kind: RemoteFile.Kind, size: Int64, modified: Date?, host: Host) {
        guard let idx = tabs.firstIndex(where: {
            $0.kind == .editor && $0.hostId == host.id && $0.filePath == oldPath
        }) else { return }   // 没在编辑器打开 → 仅树已刷新即可
        let tabId = tabs[idx].id
        if editorStates[tabId]?.isDirty == true {
            pendingFileInfo = FileInfoContext(title: "已重命名",
                message: "该文件在编辑器中有未保存的修改，标签未同步——保存仍会写到原文件名，建议先保存或关闭后再重命名。")
            return
        }
        let newFile = RemoteFile(name: newName, path: newPath, kind: kind, size: size, modified: modified)
        tabs[idx].title = newName
        tabs[idx].filePath = newPath
        editorStates[tabId]?.rebind(to: newFile)
    }

    func fileMenuRequestChmod(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        Task { @MainActor in
            let perms = await target.currentPerms(file) ?? (file.isDir ? 0o755 : 0o644)
            pendingFileChmod = ChmodContext(file: file, host: host, target: target, mode: perms)
        }
    }

    func confirmFileChmod(mode: Int) {
        guard let ctx = pendingFileChmod else { return }
        pendingFileChmod = nil
        Task { @MainActor in
            if case .failure(let e) = await ctx.target.performChmod(ctx.file, mode: String(mode, radix: 8)) {
                pendingFileInfo = FileInfoContext(title: "修改权限失败", message: e.message)
            }
        }
    }

    // MARK: - 新建文件 / 文件夹

    func fileMenuRequestCreate(isDir: Bool, inDir dir: String, host: Host, target: any FileOpsTarget) {
        pendingFileCreate = CreateContext(dir: dir, isDir: isDir, host: host, target: target)
    }

    func confirmFileCreate(name: String) {
        guard let ctx = pendingFileCreate else { return }
        pendingFileCreate = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            pendingFileInfo = FileInfoContext(title: "名称无效", message: "名称不能为空或包含「/」。")
            return
        }
        Task { @MainActor in
            if case .failure(let e) = await ctx.target.performCreate(trimmed, isDir: ctx.isDir, inDir: ctx.dir) {
                pendingFileInfo = FileInfoContext(title: ctx.isDir ? "新建文件夹失败" : "新建文件失败", message: e.message)
            }
        }
    }

    // MARK: - 下载

    /// 下载远端文件到本地：按设置取目录或每次询问目录；进度/后台复用上传那套传输对话框，完成后在访达定位。
    /// 与上传共用传输队列（可并发，超出排队）。目录暂不支持，仅文件。
    func downloadFiles(_ files: [RemoteFile], host: Host) {
        let downloadable = files.filter { !$0.isDir }
        guard !downloadable.isEmpty, let ssh = host.ssh, !ssh.host.isEmpty else { return }
        let dir: URL
        if AppSettings.shared.downloadAskEachTime {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "下载到此处"
            panel.message = "选择下载保存到的文件夹"
            panel.directoryURL = AppSettings.shared.resolvedDownloadDir
            guard panel.runModal() == .OK, let u = panel.url else { return }
            dir = u
        } else {
            dir = AppSettings.shared.resolvedDownloadDir
        }
        // 完成后不再自动弹访达窗口（打断用户）；完成提醒由系统通知给出。
        // 本地保存名去重：不覆盖已有文件、不与进行中下载撞名 → 不同主机/来源的同名文件可并发各自落地。
        let localURLs = resolveDownloadURLs(downloadable, dir: dir)
        let task = UploadTask(download: downloadable, toLocalURLs: localURLs, inDir: dir, fs: RemoteFS(ssh)) { }
        task.hostId = host.id
        task.hostName = host.name
        enqueueTransfer(task)
    }

    /// 为一批下载计算互不冲突、且不覆盖本地已有文件的保存路径：
    /// 目标名若已存在于磁盘、或已被进行中/排队/暂停的下载占用，则在扩展名前追加 “ (n)” 后缀（同 Finder/浏览器习惯）。
    /// 如此不同主机、不同来源的同名文件可各自落地并发下载，重复下载也不会覆盖旧文件。
    private func resolveDownloadURLs(_ files: [RemoteFile], dir: URL) -> [URL] {
        var taken = Set<String>()
        for t in transfers where t.direction == .download {
            switch t.phase { case .done, .cancelled: break
            default: for it in t.items { taken.insert(it.url.path) } }
        }
        let fm = FileManager.default
        var result: [URL] = []
        for f in files {
            var candidate = dir.appendingPathComponent(f.name)
            if fm.fileExists(atPath: candidate.path) || taken.contains(candidate.path) {
                let base = (f.name as NSString).deletingPathExtension
                let ext = (f.name as NSString).pathExtension
                var n = 1
                repeat {
                    let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                    candidate = dir.appendingPathComponent(newName)
                    n += 1
                } while fm.fileExists(atPath: candidate.path) || taken.contains(candidate.path)
            }
            taken.insert(candidate.path)   // 同批内也去重
            result.append(candidate)
        }
        return result
    }

    // MARK: - 解压

    /// 请求解压压缩包：弹出解压弹窗（选目标后开始），完成后局部刷新归档所在目录、发系统通知。
    /// 与上传/下载相互独立，但同一时刻只允许一个解压任务（避免迷你状态与目标目录冲突）。
    func requestExtract(_ file: RemoteFile, host: Host) {
        guard !file.isDir, let kind = ArchiveKind.detect(file.name),
              let ssh = host.ssh, !ssh.host.isEmpty else { return }
        if let t = extractTask, t.phase == .running {
            pendingFileInfo = FileInfoContext(title: "已有解压进行中",
                                              message: "请等当前解压结束后再开始新的解压。")
            return
        }
        let parent = (file.path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? "/" : parent
        let task = ExtractTask(archive: file, kind: kind, parentDir: dir,
                               fs: RemoteFS(ssh)) { [weak self] in
            self?.refreshTrees(host: host, dir: dir)
        }
        task.hostId = host.id
        task.hostName = host.name
        extractTask = task
        showExtractDialog = true
    }

    func selectTab(_ id: Int) {
        activeTabId = id
        // 切到编辑器标签时，让资源管理器高亮跟到它打开的文件
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .editor,
           let path = tab.filePath, let host = host(tab.hostId) {
            revealInExplorer(path, host: host)
        }
    }

    /// Workspace 用 ZStack 全量保活后，切 tab 不再重建视图，makeNSView 也不再自动抢焦点。
    /// 这里在 activeTabId 变化时显式把键盘焦点交给当前 tab，并确保焦点不滞留在已隐藏的会话上（防止键盘打进隐藏的终端/编辑器）。
    func focusActiveTab() {
        guard let id = activeTabId, let tab = tabs.first(where: { $0.id == id }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
            switch tab.kind {
            case .terminal:
                if let tv = self.terminals[id] { (tv.window ?? window)?.makeFirstResponder(tv) }
            case .editor:
                if let v = self.editorStates[id]?.focusView {
                    (v.window ?? window)?.makeFirstResponder(v)
                } else {
                    self.resignTabResponderIfNeeded(window)
                }
            default:
                self.resignTabResponderIfNeeded(window)
            }
        }
    }

    /// 仅当当前 first responder 落在某个 tab 视图（终端/编辑器）里时收回焦点，避免键盘打进隐藏 tab；
    /// 不动侧栏搜索框等无关焦点。
    private func resignTabResponderIfNeeded(_ window: NSWindow?) {
        guard let window, let fr = window.firstResponder as? NSView else { return }
        let inTerminal = terminals.values.contains { fr == $0 || fr.isDescendant(of: $0) }
        let inEditor = editorStates.values.contains {
            guard let v = $0.focusView else { return false }
            return fr == v || fr.isDescendant(of: v)
        }
        if inTerminal || inEditor { window.makeFirstResponder(nil) }
    }

    @Published var pendingCloseTabId: Int? = nil
    @Published var pendingTabRename: TabRenameContext? = nil      // 重命名标签输入弹窗
    @Published var pendingMultiClose: MultiCloseContext? = nil    // 批量关闭聚合确认弹窗

    func closeTab(_ id: Int) {
        if shouldConfirmClose(id) {
            pendingCloseTabId = id
        } else {
            performCloseTab(id)
        }
    }

    func confirmPendingClose() {
        if let id = pendingCloseTabId {
            performCloseTab(id)
        }
        pendingCloseTabId = nil
    }

    func cancelPendingClose() {
        pendingCloseTabId = nil
    }

    /// 在符合条件的现有标签标题内，为 base 取不重复标题：首个用 base，其后追加 " 2"、" 3"…
    private func uniqueTabTitle(_ base: String, among predicate: (TabItem) -> Bool) -> String {
        let taken = Set(tabs.filter(predicate).map(\.title))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// 请求重命名标签（弹输入框）。
    func requestRenameTab(_ id: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        pendingTabRename = TabRenameContext(id: id, currentTitle: tab.title)
    }

    /// 重命名标签：与其它标签同名则拒绝（便于区分），否则原地改名。
    func renameTab(_ id: Int, to newName: String) {
        pendingTabRename = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.contains(where: { $0.id != id && $0.title == trimmed }) {
            pendingFileInfo = FileInfoContext(title: "名称已被占用",
                message: "已有标签使用「\(trimmed)」，换一个名称以便区分。")
            return
        }
        tabs[idx].title = trimmed
    }

    /// 关闭其它标签 / 关闭全部：逐个走 performCloseTab 完成资源拆除；有需确认的（运行中会话/未保存）先聚合确认一次。
    func closeOtherTabs(keep id: Int) { requestMultiClose(tabs.filter { $0.id != id }.map(\.id)) }
    func closeAllTabs() { requestMultiClose(tabs.map(\.id)) }

    private func requestMultiClose(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        if ids.contains(where: { shouldConfirmClose($0) }) {
            pendingMultiClose = MultiCloseContext(ids: ids)
        } else {
            ids.forEach { performCloseTab($0) }
        }
    }

    func confirmMultiClose() {
        pendingMultiClose?.ids.forEach { performCloseTab($0) }
        pendingMultiClose = nil
    }
    func cancelMultiClose() { pendingMultiClose = nil }

    private func performCloseTab(_ id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closedHostId = tabs[idx].hostId
        tabs.remove(at: idx)
        // 先清空代理回调，避免 terminate 触发的 processTerminated 再次回调（重入）
        if let d = termDelegates[id] { d.onTerminated = nil; d.onCwd = nil }
        // 终止子进程（SIGTERM）并关闭 PTY fd，避免孤儿 ssh/shell 进程与 fd 泄漏
        if let tv = terminals[id] {
            tv.process.terminate()
        }
        terminals.removeValue(forKey: id)
        termDelegates.removeValue(forKey: id)
        // 取消该标签未完成的文件操作并释放浏览/树状态（按标签独立，关即释放）
        browserStates[id]?.cancel()
        browserStates.removeValue(forKey: id)
        fileTreeStates.removeValue(forKey: id)
        terminalConns.removeValue(forKey: id)   // 关标签即弃用其连接态
        terminalReconnectWork[id]?.cancel()      // 撤销该标签挂起的重连，避免关闭后仍唤醒
        terminalReconnectWork.removeValue(forKey: id)
        editorStates[id]?.cancel()
        editorStates.removeValue(forKey: id)
        editorHosts.removeValue(forKey: id)   // 释放托管的编辑器实例
        rdpSessions[id]?.disconnect()
        rdpSessions.removeValue(forKey: id)
        tabCwd.removeValue(forKey: id)
        if activeTabId == id {
            activeTabId = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
        if let hid = closedHostId { stopMonitorIfUnused(hid) }   // 主机最后一个标签关闭即停监控
    }

    /// 该终端是否有正在运行的活跃进程，需要确认后再关闭。
    private func shouldConfirmClose(_ id: Int) -> Bool {
        // 编辑器有未保存修改 → 始终确认（数据丢失风险，不受「关闭确认」开关影响）
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .editor {
            return editorStates[id]?.isDirty ?? false
        }
        guard AppSettings.shared.closeConfirm else { return false }
        // RDP 会话：关闭即断开远程桌面，始终确认
        if let tab = tabs.first(where: { $0.id == id }), tab.kind == .rdp { return true }
        guard let tab = tabs.first(where: { $0.id == id }), tab.kind == .terminal else { return false }
        guard let tv = terminals[id] else { return false }

        // SSH 会话：关闭即断开远程连接，始终确认
        if let hid = tab.hostId, hosts.first(where: { $0.id == hid })?.ssh != nil {
            return true
        }
        // 本地终端：比较 PTY 前台进程组与 shell 自身，不同则说明有前台任务在跑
        let fd = tv.process.childfd
        let shellPid = tv.process.shellPid
        guard fd >= 0, shellPid > 0 else { return false }
        let fg = tcgetpgrp(fd)
        return fg > 0 && fg != shellPid
    }

    /// 待关闭标签的标题（用于确认弹窗文案）。
    var pendingCloseTitle: String {
        guard let id = pendingCloseTabId else { return "" }
        return tabs.first(where: { $0.id == id })?.title ?? ""
    }

    /// 关闭确认弹窗标题（按标签类型区分）。
    var pendingCloseDialogTitle: String {
        guard let id = pendingCloseTabId,
              let tab = tabs.first(where: { $0.id == id }) else { return "关闭此标签？" }
        switch tab.kind {
        case .editor: return "放弃未保存的修改？"
        case .rdp:    return "断开远程桌面？"
        default:      return "关闭此终端？"
        }
    }

    /// 关闭确认弹窗正文。
    var pendingCloseDialogMessage: String {
        guard let id = pendingCloseTabId,
              let tab = tabs.first(where: { $0.id == id }) else { return "" }
        switch tab.kind {
        case .editor: return "「\(tab.title)」有尚未保存的修改，关闭后修改将丢失。"
        case .rdp:    return "「\(tab.title)」是一个远程桌面会话，关闭后将断开连接。"
        default:      return "「\(tab.title)」有正在运行的进程，关闭后进程将被终止。"
        }
    }
}

// MARK: - 标签右键操作的弹窗上下文

struct TabRenameContext: Identifiable {
    let id: Int            // 目标标签 id
    let currentTitle: String
}

struct MultiCloseContext: Identifiable {
    let id = UUID()
    let ids: [Int]         // 待关闭的标签 id 集合
}

// MARK: - 文件栏右键操作的弹窗上下文

struct FileOpContext: Identifiable {
    let id = UUID()
    let file: RemoteFile
    let host: Host
    let target: any FileOpsTarget
}

struct BatchDeleteContext: Identifiable {
    let id = UUID()
    let files: [RemoteFile]
    let host: Host
    let target: any FileOpsTarget
}

struct ChmodContext: Identifiable {
    let id = UUID()
    let file: RemoteFile
    let host: Host
    let target: any FileOpsTarget
    let mode: Int   // 当前权限（八进制值，如 0o755）
}

struct CreateContext: Identifiable {
    let id = UUID()
    let dir: String          // 在此目录下新建
    let isDir: Bool          // true=文件夹，false=文件
    let host: Host
    let target: any FileOpsTarget
}

struct RefreshConflictContext: Identifiable {
    let id = UUID()
    let editorState: EditorState
    let fileName: String
}

struct FileInfoContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
