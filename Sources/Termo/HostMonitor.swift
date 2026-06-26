import Network
import SwiftUI

/// 全局网络可达性监听。网络切换（WiFi 互换、有线无线切换、断网恢复）时 NWPathMonitor 在系统层面
/// 立即感知，用来主动触发监控重连，而不必干等 SSH keepalive 超时（约十几秒）。
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    /// 网络发生实质变化时回调，参数为当前是否在线。
    var onChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private var lastKey = ""

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // 指纹取「是否在线 + 可用网卡名集合」，仅在实质变化时通知，避免抖动重复触发。
            let key = "\(online)|" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in self?.apply(online: online, key: key) }
        }
        monitor.start(queue: DispatchQueue(label: "com.termo.netpath"))
    }

    private func apply(online: Bool, key: String) {
        guard key != lastKey else { return }
        let first = lastKey.isEmpty
        lastKey = key
        isOnline = online
        if !first { onChange?(online) }   // 跳过启动首帧，只在真正切换时触发
    }
}

/// 单台主机的实时监控。复用 SSH 跑一段内联 /proc 采样循环，流式解析每帧并发布指标。
/// 服务器不落任何文件，停止即终止远端进程；CPU 占用与网速由相邻两帧差值在本地算出。
@MainActor
final class HostMonitor: ObservableObject {
    enum Phase: Equatable { case connecting, live, unsupported, error }

    @Published private(set) var metrics: HostMetrics?
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var netHistory: [NetSample] = []   // 最近若干帧网速，供波动折线图
    @Published private(set) var netTick = 0                    // 每追加一帧自增，驱动折线整条左滑一格
    private static let netHistoryCap = 42                       // 与折线窗口（visible+2）一致，填满后无需补齐

    /// 每解析出一帧调用一次，供上层做阈值告警；监控本身只产数据、不判定告警。
    var onSample: ((HostMetrics) -> Void)?

    private let ssh: SSHConnection
    private let simulated: Bool          // true=合成数据演示主机，不连真服务器
    private var process: Process?
    private var buffer = Data()
    private var running = false            // 期望运行中；意外退出时据此决定是否重连
    private var restartWork: DispatchWorkItem?

    // 上一帧原始计数器，用于算差值
    private var prevCpu: [String: (idle: Double, total: Double)] = [:]   // 键为 cpu / cpu0 / cpu1…
    private var prevRx: Double?
    private var prevTx: Double?
    private var prevUptime: Double?

    // 采样间隔，需与远端 sleep 一致；作为网速 Δt 的兜底（实际优先用 uptime 差更准）
    private static let interval = 2

    /// 一帧采样的间隔秒数（真实流 2s、模拟 1s）；供折线图把左滑动画时长对齐采样节奏，保证连续不顿挫。
    var sampleInterval: Double { simulated ? Self.simInterval : Double(Self.interval) }

    /// 远端内联采样脚本：无 /proc 立即报 NOPROC 退出；否则每 interval 秒输出一帧，以 === 分隔。
    /// CPU 输出整机与每核（cpu / cpuN）；网络累计排除回环 lo 并把网卡名冒号换空格再取字段，避免高流量字节数
    /// 与冒号粘连错位；磁盘只列真实块设备（/dev/ 开头）的各挂载点；有 nvidia-smi 时每块 GPU 一行（| 分隔，
    /// 容纳含空格的型号名）。内存单位 kB、磁盘 1K 块、显存 MiB。
    private static let script = """
    [ -r /proc/stat ] || { echo NOPROC; exit 0; }
    command -v nvidia-smi >/dev/null 2>&1 && HASGPU=1 || HASGPU=0
    while :; do
      awk '/^cpu[0-9]* /{print "CPU "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9}' /proc/stat
      awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/{gsub(/:/,"",$1); print "MEM "$1" "$2}' /proc/meminfo
      awk 'NR>2{sub(/:/," "); if($1!="lo" && NF>=10){r+=$2; t+=$10}} END{print "NET "r" "t}' /proc/net/dev
      echo "UP $(cut -d" " -f1 /proc/uptime)"
      echo "LOAD $(cut -d" " -f1-3 /proc/loadavg)"
      df -kP 2>/dev/null | awk 'NR>1 && index($1,"/dev/")==1{print "DISK "$6" "$3" "$2}'
      [ "$HASGPU" = 1 ] && nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | awk -F", *" '{print "GPU "$1"|"$2"|"$3"|"$4"|"$5"|"$6}'
      echo "==="
      sleep __INTERVAL__
    done
    """

    init(ssh: SSHConnection, simulated: Bool = false) {
        self.ssh = ssh
        self.simulated = simulated
    }

    func start() {
        guard !running else { return }
        if simulated { running = true; startSimulation(); return }
        guard !ssh.host.isEmpty else { phase = .unsupported; return }
        running = true
        phase = .connecting
        launch()
    }

    func stop() {
        running = false
        restartWork?.cancel(); restartWork = nil
        simTimer?.invalidate(); simTimer = nil
        teardownProcess()
        buffer.removeAll()
    }

    /// 网络切换时调用：立刻丢弃当前连接重连，不等 keepalive 超时。
    /// launch 内部已对离线自守，离线则置 error 等下次网络恢复再连。
    func handleNetworkChange() {
        guard running, !simulated else { return }
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        phase = .connecting
        launch()
    }

    private func teardownProcess() {
        if let p = process {
            p.terminationHandler = nil
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
    }

    private func launch() {
        // 离线时不发起连接，等网络恢复由 handleNetworkChange 触发重连，避免离线期间空转重试。
        guard NetworkMonitor.shared.isOnline else { phase = .error; return }
        let cmd = Self.script.replacingOccurrences(of: "__INTERVAL__", with: String(Self.interval))
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // 独立连接、不复用终端 master：关掉终端不会连带掐断监控；该主机已验证过指纹故 known_hosts 命中不弹窗。
        proc.arguments = ssh.sshArguments() + ["-o", "BatchMode=no", cmd]
        var env = ProcessInfo.processInfo.environment
        if ssh.needsAskpass, let ap = SSHAskpass.envVars(password: ssh.password) {
            for (k, v) in ap { env[k] = v }
        }
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // 丢弃 stderr
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; return }   // EOF：摘掉监听，避免空读自旋
            Task { @MainActor in self?.ingest(data) }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleExit() }
        }

        prevCpu.removeAll(); prevRx = nil; prevTx = nil; prevUptime = nil
        buffer.removeAll()
        do {
            try proc.run()
            process = proc
        } catch {
            process = nil
            phase = .error
            scheduleRestart()
        }
    }

    private func handleExit() {
        process = nil
        guard running else { return }   // 我方主动停止，不重连
        phase = .error
        scheduleRestart()
    }

    /// 连接意外断开后延迟重连：主机仍打开着，保持后台监控的韧性。
    private func scheduleRestart() {
        guard running, restartWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            if self.running { self.phase = .connecting; self.launch() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        // 以 "===\n" 为帧界逐帧解析；不完整的尾部留在 buffer 等下次。
        let delim = Data("===\n".utf8)
        while let r = buffer.range(of: delim) {
            let frame = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            if let text = String(data: frame, encoding: .utf8) { parse(text) }
        }
    }

    private func parse(_ frame: String) {
        if frame.contains("NOPROC") {
            phase = .unsupported
            running = false            // 远端无 /proc，已 exit，不再重连
            return
        }

        var m = HostMetrics()
        var memAvail: Int64 = 0
        var swapFree: Int64 = 0
        var curCpu: [String: (idle: Double, total: Double)] = [:]
        var cores: [(idx: Int, pct: Double)] = []
        var curRx: Double?, curTx: Double?

        for raw in frame.split(separator: "\n") {
            let p = raw.split(separator: " ").map(String.init)
            guard let key = p.first else { continue }
            switch key {
            case "CPU":
                // CPU <名> user nice system idle iowait irq softirq steal；名为 cpu（整机）或 cpuN（单核）
                guard p.count >= 6 else { break }
                let name = p[1]
                let v = p.dropFirst(2).compactMap { Double($0) }
                guard v.count >= 4 else { break }
                let total = v.reduce(0, +)
                let idle = v[3] + (v.count > 4 ? v[4] : 0)        // idle + iowait
                curCpu[name] = (idle, total)
                if let prev = prevCpu[name], total > prev.total {
                    let pct = max(0, min(100, (1 - (idle - prev.idle) / (total - prev.total)) * 100))
                    if name == "cpu" { m.cpuPercent = pct }
                    else if let n = Int(name.dropFirst(3)) { cores.append((n, pct)) }
                }
            case "MEM":
                if p.count >= 3, let kb = Int64(p[2]) {
                    switch p[1] {
                    case "MemTotal": m.memTotalKB = kb
                    case "MemAvailable": memAvail = kb
                    case "SwapTotal": m.swapTotalKB = kb
                    case "SwapFree": swapFree = kb
                    default: break
                    }
                }
            case "NET":
                if p.count >= 3, let rx = Double(p[1]), let tx = Double(p[2]) { curRx = rx; curTx = tx }
            case "UP":
                if p.count >= 2, let up = Double(p[1]) { m.uptimeSecs = up }
            case "LOAD":
                if p.count >= 4 {
                    m.load1 = Double(p[1]) ?? 0
                    m.load5 = Double(p[2]) ?? 0
                    m.load15 = Double(p[3]) ?? 0
                }
            case "DISK":
                // DISK <挂载点> <已用KB> <总KB>；挂载点可能含空格，按「末两列为数字」反向取。
                if p.count >= 4, let u = Int64(p[p.count - 2]), let t = Int64(p[p.count - 1]), t > 0 {
                    let mount = p[1..<(p.count - 2)].joined(separator: " ")
                    m.disks.append(DiskUsage(mount: mount, usedKB: u, totalKB: t))
                }
            case "GPU":
                // GPU i|name|util|memUsedMB|memTotalMB|temp；型号名含空格，按 | 重组解析。
                let f = p.dropFirst().joined(separator: " ")
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if f.count >= 6, let idx = Int(f[0]) {
                    m.gpus.append(GPUInfo(
                        index: idx, name: f[1],
                        utilPercent: Double(f[2]) ?? 0,
                        memUsedMB: Int64(f[3]) ?? 0,
                        memTotalMB: Int64(f[4]) ?? 0,
                        tempC: Int(f[5]) ?? 0))
                }
            default:
                break
            }
        }

        m.memUsedKB = max(0, m.memTotalKB - memAvail)
        m.swapUsedKB = max(0, m.swapTotalKB - swapFree)
        m.perCore = cores.sorted { $0.idx < $1.idx }.map { $0.pct }
        m.gpus.sort { $0.index < $1.index }
        prevCpu = curCpu

        // 网速：字节差 / Δt（优先 uptime 差，兜底用采样间隔）
        let dt = (prevUptime.map { m.uptimeSecs - $0 }).flatMap { $0 > 0 ? $0 : nil } ?? Double(Self.interval)
        if let rx = curRx, let prx = prevRx, rx >= prx { m.netRxBytesPerSec = (rx - prx) / dt }
        if let tx = curTx, let ptx = prevTx, tx >= ptx { m.netTxBytesPerSec = (tx - ptx) / dt }
        prevRx = curRx; prevTx = curTx
        prevUptime = m.uptimeSecs

        if let rx = m.netRxBytesPerSec, let tx = m.netTxBytesPerSec {
            netHistory.append(NetSample(rx: rx, tx: tx))
            if netHistory.count > Self.netHistoryCap { netHistory.removeFirst(netHistory.count - Self.netHistoryCap) }
            netTick &+= 1
        }

        metrics = m
        phase = .live
        onSample?(m)
    }

    // MARK: - 模拟演示

    private var simTimer: Timer?
    private static let simInterval = 1.0
    private var simCores: [Double] = []
    private var simBaseLoad = 0.0            // CPU 基础负载，缓慢漂移；各核围绕它波动，使热力图协调、与均值吻合
    private var simCoreOffset: [Double] = [] // 每核固定偏移（个别核常驻高负载，模拟真实热点）
    private var simMemTotalKB: Int64 = 0
    private var simMemUsedKB = 0.0
    private var simSwapTotalKB: Int64 = 0
    private var simSwapUsedKB = 0.0
    private var simDisks: [(mount: String, totalKB: Int64, usedKB: Double)] = []
    private var simGpus: [(name: String, util: Double, memUsedMB: Double, memTotalMB: Int64, temp: Double)] = []
    private var simRx = 0.0
    private var simTx = 0.0
    private var simUptime = 0.0

    /// 随机游走：在 [lo, hi] 内按 step 抖动，让模拟数据看起来在动。
    private static func walk(_ v: Double, _ step: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, v + Double.random(in: -step...step)))
    }

    private func startSimulation() {
        simBaseLoad = 52
        simCoreOffset = (0..<64).map { _ in Double.random(in: -10...10) }
        simCoreOffset[3] = 44; simCoreOffset[28] = 38   // 个别核常驻高负载，模拟真实热点
        simCores = simCoreOffset.map { min(100, max(0, simBaseLoad + $0)) }
        simMemTotalKB = 125_000_000          // ≈ 128 GB
        simMemUsedKB = Double(simMemTotalKB) * 0.55
        simSwapTotalKB = 8_000_000
        simSwapUsedKB = Double(simSwapTotalKB) * 0.1
        simDisks = [
            ("/", 500_000_000, 500_000_000 * 0.58),
            ("/data", 4_000_000_000, 4_000_000_000 * 0.34),
            ("/backup", 8_000_000_000, 8_000_000_000 * 0.92),   // 高占用，演示 CRITICAL 转红
        ]
        simGpus = [
            ("NVIDIA RTX 4090", 72, 24576 * 0.55, 24576, 68),
            ("NVIDIA RTX 4090", 18, 24576 * 0.12, 24576, 51),
        ]
        simRx = 6_000_000
        simTx = 1_200_000
        simUptime = 20_157_120   // 233 天 7 时 12 分（233*86400 + 7*3600 + 12*60）
        phase = .live
        simulateTick()
        simTimer = Timer.scheduledTimer(withTimeInterval: Self.simInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.simulateTick() }
        }
    }

    private func simulateTick() {
        simBaseLoad = Self.walk(simBaseLoad, 4, 12, 88)
        for i in simCores.indices {
            simCores[i] = min(100, max(0, simBaseLoad + simCoreOffset[i] + Double.random(in: -5...5)))
        }
        var m = HostMetrics()
        m.perCore = simCores
        let avg = simCores.isEmpty ? 0 : simCores.reduce(0, +) / Double(simCores.count)
        m.cpuPercent = avg
        let cc = Double(simCores.count)
        m.load1 = max(0, avg / 100 * cc + Double.random(in: -2...2))
        m.load5 = max(0, avg / 100 * cc * 0.92 + Double.random(in: -1.5...1.5))
        m.load15 = max(0, avg / 100 * cc * 0.85 + Double.random(in: -1...1))

        simMemUsedKB = Self.walk(simMemUsedKB, Double(simMemTotalKB) * 0.02,
                                 Double(simMemTotalKB) * 0.25, Double(simMemTotalKB) * 0.88)
        m.memTotalKB = simMemTotalKB
        m.memUsedKB = Int64(simMemUsedKB)
        simSwapUsedKB = Self.walk(simSwapUsedKB, Double(simSwapTotalKB) * 0.01, 0, Double(simSwapTotalKB) * 0.4)
        m.swapTotalKB = simSwapTotalKB
        m.swapUsedKB = Int64(simSwapUsedKB)

        m.disks = simDisks.indices.map { i in
            simDisks[i].usedKB = Self.walk(simDisks[i].usedKB, Double(simDisks[i].totalKB) * 0.004,
                                           Double(simDisks[i].totalKB) * 0.05, Double(simDisks[i].totalKB) * 0.985)
            return DiskUsage(mount: simDisks[i].mount, usedKB: Int64(simDisks[i].usedKB), totalKB: simDisks[i].totalKB)
        }

        m.gpus = simGpus.indices.map { i in
            simGpus[i].util = Self.walk(simGpus[i].util, 12, 2, 99)
            simGpus[i].memUsedMB = Self.walk(simGpus[i].memUsedMB, Double(simGpus[i].memTotalMB) * 0.03,
                                             Double(simGpus[i].memTotalMB) * 0.1, Double(simGpus[i].memTotalMB) * 0.95)
            // 温度随利用率：空闲约 40℃、满载约 85℃，更贴近真实
            simGpus[i].temp = 40.0 + simGpus[i].util * 0.45 + Double.random(in: -2...2)
            return GPUInfo(index: i, name: simGpus[i].name, utilPercent: simGpus[i].util,
                           memUsedMB: Int64(simGpus[i].memUsedMB), memTotalMB: simGpus[i].memTotalMB,
                           tempC: Int(simGpus[i].temp))
        }

        simRx = Self.walk(simRx, 5_000_000, 100_000, 90_000_000)
        simTx = Self.walk(simTx, 1_200_000, 50_000, 18_000_000)
        m.netRxBytesPerSec = simRx
        m.netTxBytesPerSec = simTx
        netHistory.append(NetSample(rx: simRx, tx: simTx))
        if netHistory.count > Self.netHistoryCap { netHistory.removeFirst(netHistory.count - Self.netHistoryCap) }
        netTick &+= 1

        simUptime += Self.simInterval
        m.uptimeSecs = simUptime

        metrics = m
        phase = .live
        onSample?(m)
    }
}
