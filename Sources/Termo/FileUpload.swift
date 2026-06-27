import SwiftUI

// MARK: - 状态

enum ItemState: Equatable {
    case waiting          // 待传
    case checking         // 探测远端（同名/续传）
    case asking           // 命中同名，等用户决策
    case uploading        // 传输中（含压缩到临时文件）
    case done             // 完成
    case skipped          // 用户跳过
    case failed(String)   // 失败（保留 message；非压缩可续传）
    case cancelled        // 被取消
}

enum SessionPhase: Equatable { case queued, running, paused, done, cancelled }
enum TransferDirection { case upload, download }

enum OverwriteDecision { case overwrite, skip, cancel }
enum AskAction { case overwrite, skip, overwriteAll, skipAll, cancel }
enum BulkPolicy { case ask, overwriteAll, skipAll }

/// 单个待上传文件（引用类型 → 列表行单独订阅，避免整列表刷新）。
@MainActor
final class UploadItem: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let url: URL
    let name: String
    let localSize: Int64
    let remotePath: String

    @Published var state: ItemState = .waiting
    @Published var sent: Int64 = 0          // 已确认字节（用于进度与总量）
    var interrupted = false                 // 失败留下半截、可续传

    /// 上传项：url=本地源文件，remotePath=远端目标。
    init(url: URL, destDir: String) {
        self.url = url
        self.name = url.lastPathComponent
        self.localSize = UploadItem.fileSize(url)
        self.remotePath = destDir.hasSuffix("/") ? destDir + name : destDir + "/" + name
    }

    /// 下载项：remotePath=远端源，url=本地目标（已由上层去重，避免覆盖本地已有文件/与其它下载撞名），
    /// name 取实际落地文件名（可能带 “ (n)” 后缀），localSize=远端大小（用作进度分母）。
    init(download file: RemoteFile, toLocalURL url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.localSize = file.size
        self.remotePath = file.path
    }

    var fraction: Double {
        localSize > 0 ? min(1, Double(sent) / Double(localSize)) : (state == .done ? 1 : 0)
    }
    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

struct AskContext: Identifiable {
    let id = UUID()
    let name: String
    let remoteSize: Int64
    let localSize: Int64
}

// MARK: - 上传任务

@MainActor
final class UploadTask: ObservableObject {
    nonisolated let id = UUID()
    let direction: TransferDirection
    let destDir: String
    let totalBytes: Int64
    // 所属主机（用于后台中控按主机分组；创建后即设，仅展示用）
    var hostId: String? = nil
    var hostName: String = ""
    private let fs: RemoteFS
    private let onAllDone: () -> Void

    @Published var items: [UploadItem]
    @Published var phase: SessionPhase = .queued    // 初始排队；由协调器调用 start() 出队转 .running
    /// 任务进入终态（完成/取消）时回调一次，供上层推进传输队列。
    var onFinished: (() -> Void)? = nil
    /// 暂停/请求恢复后回调，供协调器重新泵队列（补位排队任务、放行等待名额的恢复请求）。
    var onPauseStateChanged: (() -> Void)? = nil
    /// 用户已点「继续」但当前无空闲名额，处于「等待协调器放行」状态（phase 仍为 .paused）。
    @Published private(set) var awaitingSlot = false

    /// 逐文件目标互斥锁（由协调器 AppModel 注入）：传输每个文件前后获取/释放，
    /// 仅当两任务真要同时写同一目标文件时才串行，避免 .part 临时文件互相覆盖；其余文件照常并发。
    var acquirePathLock: ((String) async -> Void)? = nil
    var releasePathLock: ((String) -> Void)? = nil

    /// 单个目标文件的锁键：上传以「主机+远端路径」（.part 临时名相同才会撞），下载以本地路径。
    private func lockKey(_ item: UploadItem) -> String {
        switch direction {
        case .upload:   return "up:\(hostId ?? ""):\(item.remotePath)"
        case .download: return "down:\(item.url.path)"
        }
    }
    @Published var index = 0
    @Published var overallSent: Int64 = 0
    @Published var speed: Double = 0
    @Published var pendingAsk: AskContext? = nil

    private let control = UploadControl()
    private var bulkPolicy: BulkPolicy = .ask
    private var askCont: CheckedContinuation<OverwriteDecision, Never>?
    private var resumeCont: CheckedContinuation<Void, Never>?   // 暂停时挂起主循环，恢复时唤醒
    private var lastSampledOverall: Int64 = 0
    private var pendingBaselineReset = true
    private var started = false
    private var heldLockKey: String? = nil   // 当前持有的逐文件写锁（暂停期间保留，结束时释放）

    /// 切换到目标文件 `key` 的写锁：先放掉旧锁（懒释放，上一文件已处理完），再获取新锁。
    /// 同一文件重复进入（暂停后恢复）不会重复获取。
    private func switchLock(to key: String) async {
        if heldLockKey == key { return }
        if let h = heldLockKey { releasePathLock?(h); heldLockKey = nil }
        await acquirePathLock?(key)
        heldLockKey = key
    }
    /// 释放当前持有的写锁（任务收尾或被取消时）。
    private func releaseHeldLock() {
        if let h = heldLockKey { releasePathLock?(h); heldLockKey = nil }
    }

    init(files: [URL], destDir: String, fs: RemoteFS, onAllDone: @escaping () -> Void) {
        self.direction = .upload
        self.destDir = destDir
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = files.map { UploadItem(url: $0, destDir: destDir) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    /// 下载任务：把远端文件拉到本地。`localURLs` 与 `files` 一一对应，由上层去重产出
    /// （不覆盖本地已有文件、不与其它进行中下载撞名，必要时加 “ (n)” 后缀），`dir` 仅用于展示保存位置。
    init(download files: [RemoteFile], toLocalURLs localURLs: [URL], inDir dir: URL,
         fs: RemoteFS, onAllDone: @escaping () -> Void) {
        self.direction = .download
        self.destDir = dir.path
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = zip(files, localURLs).map { UploadItem(download: $0, toLocalURL: $1) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    func start() {
        guard !started else { return }
        started = true
        phase = .running            // 出队开跑（初始为 .queued）
        pendingBaselineReset = true
        Task { await sampleLoop() }
        Task { await run() }
    }

    private func run() async {
        if direction == .download { await runDownload() } else { await runFrom() }
    }

    func cancel() {
        if phase == .queued {           // 尚未开始：直接取消并出队（让协调器推进下一个）
            phase = .cancelled
            onFinished?()
            return
        }
        guard phase == .running || phase == .paused else { return }
        control.set(.cancel)
        // 若卡在同名询问，唤醒它（否则 runFrom 挂在 await 上，cancel 无效）
        if let cont = askCont { askCont = nil; pendingAsk = nil; cont.resume(returning: .cancel) }
        wakeFromPause()   // 暂停态取消：唤醒挂起的主循环，使其看到 .cancel 后收尾
    }

    /// 暂停：停掉当前传输（保留半截 .part / 本地半截），主循环挂起等待恢复。
    func pause() {
        guard phase == .running else { return }
        phase = .paused
        awaitingSlot = false
        control.set(.pause)
        onPauseStateChanged?()   // 可能空出名额，让协调器补位排队任务
    }

    /// 用户请求恢复：由协调器调用，`slotFree` 表示当前是否有空闲名额。
    /// 有空位则立即续传；无空位则标记 awaitingSlot，待协调器在名额释放时放行（admitResume）。
    func requestResume(slotFree: Bool) {
        guard phase == .paused else { return }
        if slotFree {
            actuallyResume()
        } else {
            awaitingSlot = true
            onPauseStateChanged?()   // 刷新 UI 为「等待中」
        }
    }

    /// 协调器放行一个「等待名额」的恢复请求（已确认有空位）。
    func admitResume() {
        guard phase == .paused, awaitingSlot else { return }
        actuallyResume()
    }

    /// 实际恢复：从断点续传当前文件，主循环继续推进。
    private func actuallyResume() {
        awaitingSlot = false
        phase = .running
        control.set(.run)
        pendingBaselineReset = true
        Task { await sampleLoop() }   // 采样循环在暂停时已退出，需重启
        wakeFromPause()
    }

    /// 主循环在暂停期间挂起；恢复/取消时由 wakeFromPause 唤醒。
    /// 取消信号也作为退出条件：否则取消时 phase 仍是 .paused，唤醒后会立刻重新挂起，导致取消无效。
    private func waitIfPaused() async {
        while phase == .paused, control.signal != .cancel {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in resumeCont = c }
        }
    }
    private func wakeFromPause() {
        if let c = resumeCont { resumeCont = nil; c.resume() }
    }

    /// 跑完后重试/续传失败项。
    func retryFailed(resume: Bool) {
        guard phase == .done else { return }
        for it in items {
            if case .failed = it.state {
                if !resume { it.interrupted = false }   // 重试=从 0；续传=保留半截
                it.state = .waiting
            }
        }
        index = 0
        phase = .running
        control.set(.run)
        pendingBaselineReset = true
        Task { await sampleLoop() }
        Task { await run() }
    }

    func resolveAsk(_ a: AskAction) {
        pendingAsk = nil
        let cont = askCont; askCont = nil
        switch a {
        case .overwrite:    cont?.resume(returning: .overwrite)
        case .skip:         cont?.resume(returning: .skip)
        case .overwriteAll: bulkPolicy = .overwriteAll; cont?.resume(returning: .overwrite)
        case .skipAll:      bulkPolicy = .skipAll;      cont?.resume(returning: .skip)
        case .cancel:       cont?.resume(returning: .cancel)
        }
    }

    // MARK: 主循环

    private func runFrom() async {
        while index < items.count {
            if control.signal == .cancel { break }
            let item = items[index]
            if item.state == .done || item.state == .skipped || item.state == .cancelled {
                index += 1; continue
            }
            await switchLock(to: lockKey(item))   // 同名文件互斥：取得本文件写锁（暂停恢复同文件不重复获取）
            if control.signal == .cancel { break } // 等锁期间可能被取消
            item.state = .checking
            pendingBaselineReset = true
            let probe = await fs.probeUpload(remotePath: item.remotePath)
            // 续传：本会话失败留半截（interrupted），或上次取消/失败保留的远端 .part
            //（远端有未完整 .part 且无正式文件 → 从上次断点接着传）。
            let resuming = item.interrupted
                || (probe.partSize > 0 && probe.partSize < item.localSize && !probe.finalExists)

            if !resuming, probe.finalExists {
                switch await resolveOverwrite(item: item, finalSize: probe.finalSize) {
                case .skip:      item.state = .skipped; index += 1; continue
                case .cancel:    control.set(.cancel)
                case .overwrite: break   // cat> 截断 .part，finalize 覆盖正式文件
                }
            }
            if control.signal == .cancel { break }

            // 续传偏移（仅非压缩续传）：以远端 .part 实际大小为准（审查 R1）
            var startOffset: Int64 = 0
            if resuming {
                startOffset = min(probe.partSize, item.localSize)
                if startOffset >= item.localSize, item.localSize > 0 {   // .part 已完整 → 直接落地
                    item.sent = item.localSize
                    item.state = (try? await fs.finalizeUpload(remotePath: item.remotePath).get()) != nil
                        ? .done : .failed("落地失败")
                    index += 1; continue
                }
            }

            item.state = .uploading
            control.set(.run)
            control.setSent(startOffset)

            let outcome = await fs.upload(localURL: item.url, toRemote: item.remotePath,
                                          startOffset: startOffset, control: control)

            switch outcome {
            case .completed:
                item.sent = item.localSize
                item.interrupted = false
                item.state = (try? await fs.finalizeUpload(remotePath: item.remotePath).get()) != nil
                    ? .done : .failed("落地失败")
                index += 1
            case .cancelled:
                control.set(.cancel)
            case .paused:
                item.interrupted = true             // 保留远端 .part，恢复后从断点续传（不前进 index）
            case .failed(let msg):
                item.interrupted = true             // 保留半截 .part 供续传（偏移续传时再 probe）
                item.state = .failed(msg)
                index += 1                          // 单文件失败不中断队列
            }
            if control.signal == .cancel { break }
            await waitIfPaused()                     // 暂停则挂起，恢复后回到循环重传当前项（保留文件写锁）
        }
        finish()   // finish() 内统一释放写锁并回收 SFTP 会话
    }

    /// 下载主循环：逐个把远端文件流式拉到本地（带进度/取消）。无同名询问/续传（更简单）。
    private func runDownload() async {
        while index < items.count {
            if control.signal == .cancel { break }
            let item = items[index]
            if item.state == .done { index += 1; continue }
            await switchLock(to: lockKey(item))   // 同名本地目标互斥：避免两任务同时写同一文件
            if control.signal == .cancel { break }
            item.state = .uploading        // 复用「传输中」态
            control.set(.run)
            // 暂停恢复：本地已有半截则从其大小续传，远端从该偏移继续读
            let startOffset: Int64 = item.interrupted ? UploadItem.fileSize(item.url) : 0
            control.setSent(startOffset)
            pendingBaselineReset = true
            let outcome = await fs.download(item.remotePath, to: item.url, startOffset: startOffset, control: control)
            switch outcome {
            case .completed:
                item.sent = item.localSize
                item.interrupted = false
                item.state = .done
                index += 1
            case .cancelled:
                control.set(.cancel)
            case .paused:
                item.interrupted = true             // 保留本地半截，恢复后续传（不前进 index）
            case .failed(let msg):
                try? FileManager.default.removeItem(at: item.url)   // 删掉下了一半的本地残文件
                item.interrupted = false
                item.state = .failed(msg)
                index += 1
            }
            if control.signal == .cancel { break }
            await waitIfPaused()
        }
        finish()   // finish() 内统一释放写锁并回收 SFTP 会话
    }

    private func resolveOverwrite(item: UploadItem, finalSize: Int64) async -> OverwriteDecision {
        if control.signal == .cancel { return .cancel }
        switch bulkPolicy {
        case .overwriteAll: return .overwrite
        case .skipAll:      return .skip
        case .ask:          break
        }
        item.state = .asking
        let ctx = AskContext(name: item.name, remoteSize: finalSize, localSize: item.localSize)
        return await withCheckedContinuation { cont in
            askCont = cont
            pendingAsk = ctx
        }
    }

    private func finish() {
        let landedAny = items.contains { $0.state == .done }
        if control.signal == .cancel {
            for it in items {
                switch it.state {
                case .done, .skipped, .failed: break
                default:
                    it.state = .cancelled
                    if direction == .download { try? FileManager.default.removeItem(at: it.url) }   // 删半截本地文件
                }
            }
            phase = .cancelled
        } else {
            phase = .done
            postCompletionNotification()
        }
        if landedAny { onAllDone() }
        releaseHeldLock()       // 释放当前持有的逐文件写锁
        fs.closeSession()       // 终态立即回收 SFTP 子进程/读循环线程/缓冲（记录仍留列表也不再占内存）
        onFinished?()           // 终态：推进传输队列
    }

    private func postCompletionNotification() {
        let verb = direction == .upload ? "上传" : "下载"
        let done = items.filter { $0.state == .done }.count
        if hasFailures {
            Notifier.notify(title: "\(verb)部分失败", body: "成功 \(done)/\(items.count) 个文件")
        } else {
            Notifier.notify(title: "\(verb)完成", body: "\(done) 个文件 · \(humanSize(totalBytes))")
        }
    }

    // MARK: 速度采样（0.1s + EMA 平滑；压缩时把「已传压缩字节」映射回原始字节空间）

    private func sampleLoop() async {
        let dt = 0.1
        while phase == .running {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if index < items.count, items[index].state == .uploading {
                let it = items[index]
                it.sent = max(it.sent, min(it.localSize, control.sent))
            }
            let overall = items.reduce(0) { $0 + $1.sent }
            overallSent = overall
            if pendingBaselineReset {
                lastSampledOverall = overall
                pendingBaselineReset = false
            } else {
                let instant = max(0, Double(overall - lastSampledOverall) / dt)
                lastSampledOverall = overall
                speed = speed * 0.7 + instant * 0.3   // EMA 平滑
            }
        }
    }

    // MARK: 派生

    /// 分母剔除跳过/取消项（审查 R14）。
    var effectiveTotal: Int64 {
        items.reduce(0) { (it: Int64, x) in
            (x.state == .skipped || x.state == .cancelled) ? it : it + x.localSize
        }
    }
    var eta: Double {
        guard speed > 1, phase == .running else { return 0 }
        return Double(effectiveTotal - overallSent) / speed
    }
    var hasFailures: Bool { items.contains { if case .failed = $0.state { return true }; return false } }

    /// 是否存在"传了一半被取消/失败"的远端残留 .part（可保留以便下次续传，或删除）。仅上传有此概念。
    var hasPartials: Bool { direction == .upload && items.contains { partialRemotePath($0) != nil } }

    /// 删除所有残留 .part（用户取消时选择"删除残留"）。best-effort，失败靠下次 probe 自愈。
    func cleanupPartials() {
        let paths = items.compactMap(partialRemotePath)
        guard !paths.isEmpty else { return }
        let fs = self.fs
        Task { for p in paths { await fs.cleanupPart(remotePath: p) }; fs.closeSession() }   // 删完即关，勿留会话
    }

    private func partialRemotePath(_ it: UploadItem) -> String? {
        guard it.sent > 0, it.sent < it.localSize else { return nil }
        switch it.state { case .cancelled, .failed: return it.remotePath; default: return nil }
    }
}

// MARK: - 上传弹窗

struct UploadDialog: View {
    @ObservedObject var task: UploadTask
    let onHide: () -> Void
    let onClose: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(theme.isDark ? 0.42 : 0.20).ignoresSafeArea()
            card
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fileList
            infoRow
            if let ask = task.pendingAsk { askPanel(ask) }
            if task.phase == .cancelled, task.hasPartials {
                Text("已取消，远端残留半截文件。「保留」可下次从断点续传，「删除残留」清掉它。")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(18)
        .frame(width: 480)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 24, y: 8)
    }

    private var header: some View {
        let isUp = task.direction == .upload
        return HStack(spacing: 10) {
            Image(systemName: isUp ? "square.and.arrow.up" : "square.and.arrow.down")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.mauve)
                .frame(width: 30, height: 30)
                .background(Pal.mauve.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(isUp ? "上传文件" : "下载文件").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                Text("到 \(task.destDir)")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            statusBadge
            Button(action: onHide) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.06), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("后台运行（在左下角继续显示进度）")
        }
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, fg): (String, Color) = {
            switch task.phase {
            case .queued:    return ("排队中", Pal.overlay)
            case .running:   return ("\(min(task.index + 1, task.items.count))/\(task.items.count)", Pal.mauve)
            case .paused:    return ("已暂停", Pal.yellow)
            case .done:      return task.hasFailures ? ("部分失败", Pal.yellow) : ("完成", Pal.green)
            case .cancelled: return ("已取消", Pal.overlay)
            }
        }()
        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(fg.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(task.items) { item in UploadRow(item: item, direction: task.direction) }
            }
        }
        .frame(maxHeight: 176)
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.06), lineWidth: 1))
    }

    // 速率 + 已传/总 + 剩余时间，一行水平放（文件列表里每行已有进度条，故无底部总条）
    private var infoRow: some View {
        HStack(spacing: 12) {
            Label(fmtSpeed(task.speed), systemImage: "speedometer")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.mauve)
            Text("\(humanSize(task.overallSent)) / \(humanSize(task.totalBytes))")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            Spacer()
            if task.phase == .running {
                Text("剩余 \(fmtETA(task.eta))").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
    }

    @ViewBuilder private func askPanel(_ ask: AskContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("「\(ask.name)」远端已存在")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
            Text("远端 \(humanSize(ask.remoteSize)) · 本地 \(humanSize(ask.localSize))")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            HStack(spacing: 8) {
                pill("覆盖", fg: Pal.mauve, base: Pal.mauve.opacity(0.14)) { task.resolveAsk(.overwrite) }
                pill("跳过", fg: Pal.subtext, base: Pal.fill(0.07)) { task.resolveAsk(.skip) }
                Spacer()
                pill("全部覆盖", fg: Pal.overlay, base: Pal.fill(0.07)) { task.resolveAsk(.overwriteAll) }
                pill("全部跳过", fg: Pal.overlay, base: Pal.fill(0.07)) { task.resolveAsk(.skipAll) }
            }
        }
        .padding(10)
        .background(Pal.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.yellow.opacity(0.20), lineWidth: 1))
    }

    private var buttons: some View {
        HStack {
            Spacer()
            switch task.phase {
            case .queued:
                pill("取消", fg: Pal.subtext, base: Pal.fill(0.07)) { task.cancel() }
            case .running:
                pill("暂停", fg: Pal.mauve, base: Pal.mauve.opacity(0.14)) { AppModel.shared.pauseTransfer(task) }
                pill("取消", fg: Pal.subtext, base: Pal.fill(0.07)) { task.cancel() }
            case .paused:
                pill(task.awaitingSlot ? "等待名额…" : "继续", fg: Pal.mauve, base: Pal.mauve.opacity(0.14)) {
                    AppModel.shared.resumeTransfer(task)
                }
                pill("取消", fg: Pal.subtext, base: Pal.fill(0.07)) { task.cancel() }
            case .done where task.hasFailures:
                if task.direction == .upload {   // 续传仅上传支持（远端 .part）
                    pill("续传失败项", fg: Pal.mauve, base: Pal.mauve.opacity(0.14)) { task.retryFailed(resume: true) }
                }
                pill("重试", fg: Pal.subtext, base: Pal.fill(0.07)) { task.retryFailed(resume: false) }
                pill("关闭", fg: Pal.overlay, base: Pal.fill(0.07), action: onClose)
            case .cancelled where task.hasPartials:
                pill("保留残留（下次续传）", fg: Pal.mauve, base: Pal.mauve.opacity(0.14), action: onClose)
                pill("删除残留", fg: Pal.subtext, base: Pal.fill(0.07)) { task.cleanupPartials(); onClose() }
            case .done, .cancelled:
                pill(task.phase == .done ? "完成" : "关闭",
                     fg: Pal.mauve, base: Pal.mauve.opacity(0.14), action: onClose)
            }
        }
    }

    private func pill(_ title: String, fg: Color, base: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(fg)
                .padding(.horizontal, 14).padding(.vertical, 6.5)
                .background(base, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func fmtSpeed(_ bps: Double) -> String { bps < 1 ? "—" : humanSize(Int64(bps)) + "/s" }
    private func fmtETA(_ sec: Double) -> String {
        guard sec.isFinite, sec > 0 else { return "—" }
        let s = Int(sec.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 文件列表行（单独订阅 item）。
struct UploadRow: View {
    @ObservedObject var item: UploadItem
    var direction: TransferDirection = .upload

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color).frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).font(.system(size: 11.5)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(label).font(.system(size: 10)).foregroundStyle(color)
                }
                if showBar {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Pal.fill(0.06))
                            Capsule().fill(color).frame(width: max(0, g.size.width * item.fraction))
                                .animation(.linear(duration: 0.1), value: item.fraction)
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var showBar: Bool {
        switch item.state { case .uploading, .done: return true; default: return false }
    }
    private var icon: String {
        switch item.state {
        case .waiting:   return "clock"
        case .checking:  return "magnifyingglass"
        case .asking:    return "questionmark.circle"
        case .uploading: return direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .done:      return "checkmark.circle.fill"
        case .skipped:   return "forward.circle"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }
    private var color: Color {
        switch item.state {
        case .uploading: return Pal.mauve
        case .asking:    return Pal.yellow
        case .done:      return Pal.green
        case .failed:    return Pal.red
        default:         return Pal.overlay
        }
    }
    private var label: String {
        switch item.state {
        case .waiting:   return "待传"
        case .checking:  return "检测中"
        case .asking:    return "待决策"
        case .uploading: return "\(Int(item.fraction * 100))%"
        case .done:      return "完成"
        case .skipped:   return "已跳过"
        case .failed(let m): return m.isEmpty ? "失败" : m
        case .cancelled: return "已取消"
        }
    }
}

// 后台传输进度已并入左下角「后台任务」统一中控（见 BackgroundCenterView）。
