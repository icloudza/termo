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

enum SessionPhase: Equatable { case running, done, cancelled }
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

    /// 下载项：remotePath=远端源，url=本地目标，localSize=远端大小（用作进度分母）。
    init(download file: RemoteFile, toLocalDir dir: URL) {
        self.url = dir.appendingPathComponent(file.name)
        self.name = file.name
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
    private let fs: RemoteFS
    private let onAllDone: () -> Void

    @Published var items: [UploadItem]
    @Published var phase: SessionPhase = .running   // 选完即跑（无「开始」步骤）
    @Published var index = 0
    @Published var overallSent: Int64 = 0
    @Published var speed: Double = 0
    @Published var pendingAsk: AskContext? = nil

    private let control = UploadControl()
    private var bulkPolicy: BulkPolicy = .ask
    private var askCont: CheckedContinuation<OverwriteDecision, Never>?
    private var lastSampledOverall: Int64 = 0
    private var pendingBaselineReset = true
    private var started = false

    init(files: [URL], destDir: String, fs: RemoteFS, onAllDone: @escaping () -> Void) {
        self.direction = .upload
        self.destDir = destDir
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = files.map { UploadItem(url: $0, destDir: destDir) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    /// 下载任务：把远端文件拉到本地目录。
    init(download files: [RemoteFile], toLocalDir dir: URL, fs: RemoteFS, onAllDone: @escaping () -> Void) {
        self.direction = .download
        self.destDir = dir.path
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = files.map { UploadItem(download: $0, toLocalDir: dir) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    func start() {
        guard !started else { return }
        started = true
        pendingBaselineReset = true
        Task { await sampleLoop() }
        Task { await run() }
    }

    private func run() async {
        if direction == .download { await runDownload() } else { await runFrom() }
    }

    func cancel() {
        guard phase == .running else { return }
        control.set(.cancel)
        // 若卡在同名询问，唤醒它（否则 runFrom 挂在 await 上，cancel 无效）
        if let cont = askCont { askCont = nil; pendingAsk = nil; cont.resume(returning: .cancel) }
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
            case .failed(let msg):
                item.interrupted = true             // 保留半截 .part 供续传（偏移续传时再 probe）
                item.state = .failed(msg)
                index += 1                          // 单文件失败不中断队列
            }
            if control.signal == .cancel { break }
        }
        finish()
    }

    /// 下载主循环：逐个把远端文件流式拉到本地（带进度/取消）。无同名询问/续传（更简单）。
    private func runDownload() async {
        while index < items.count {
            if control.signal == .cancel { break }
            let item = items[index]
            if item.state == .done { index += 1; continue }
            item.state = .uploading        // 复用「传输中」态
            control.set(.run)
            control.setSent(0)
            pendingBaselineReset = true
            let outcome = await fs.download(item.remotePath, to: item.url, control: control)
            switch outcome {
            case .completed:
                item.sent = item.localSize
                item.state = .done
                index += 1
            case .cancelled:
                control.set(.cancel)
            case .failed(let msg):
                try? FileManager.default.removeItem(at: item.url)   // 删掉下了一半的本地残文件
                item.state = .failed(msg)
                index += 1
            }
            if control.signal == .cancel { break }
        }
        finish()
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
        Task { for p in paths { await fs.cleanupPart(remotePath: p) } }
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
            case .running:   return ("\(min(task.index + 1, task.items.count))/\(task.items.count)", Pal.mauve)
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
            case .running:
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

// MARK: - 后台上传迷你进度

/// 上传弹窗隐藏后，显示在活动栏底部的迷你进度环；点击重新展开弹窗。
struct UploadMiniIndicator: View {
    @ObservedObject var task: UploadTask
    let onTap: () -> Void
    @State private var hover = false

    private var fraction: CGFloat {
        task.totalBytes > 0 ? CGFloat(min(1, Double(task.overallSent) / Double(task.totalBytes))) : 0
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle().stroke(Pal.fill(0.14), lineWidth: 3)
                Circle().trim(from: 0, to: task.phase == .running ? max(0.03, fraction) : 1)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.15), value: fraction)
                Image(systemName: centerIcon).font(.system(size: 9, weight: .bold)).foregroundStyle(ringColor)
            }
            .frame(width: 22, height: 22)
            .frame(width: 38, height: 38)
            .background(hover ? Pal.fill(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .help(helpText)
        // 后台运行时若需用户确认（同名文件），自动展开弹窗，避免静默卡住。
        .onChange(of: task.pendingAsk?.id) { id in if id != nil { onTap() } }
    }

    private var ringColor: Color {
        if task.pendingAsk != nil { return Pal.yellow }
        switch task.phase {
        case .running:   return Pal.mauve
        case .done:      return task.hasFailures ? Pal.yellow : Pal.green
        case .cancelled: return Pal.overlay
        }
    }
    private var centerIcon: String {
        if task.pendingAsk != nil { return "questionmark" }
        switch task.phase {
        case .running:   return task.direction == .upload ? "arrow.up" : "arrow.down"
        case .done:      return task.hasFailures ? "exclamationmark" : "checkmark"
        case .cancelled: return "xmark"
        }
    }
    private var helpText: String {
        let verb = task.direction == .upload ? "上传" : "下载"
        if task.pendingAsk != nil { return "需要确认（同名文件）· 点击处理" }
        switch task.phase {
        case .running:   return "\(verb)中 \(Int(fraction * 100))% · 点击展开"
        case .done:      return task.hasFailures ? "\(verb)部分失败 · 点击查看" : "\(verb)完成 · 点击查看"
        case .cancelled: return "\(verb)已取消 · 点击查看"
        }
    }
}
