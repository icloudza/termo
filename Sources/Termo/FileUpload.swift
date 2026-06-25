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

    init(url: URL, destDir: String) {
        self.url = url
        self.name = url.lastPathComponent
        self.localSize = UploadItem.fileSize(url)
        self.remotePath = destDir.hasSuffix("/") ? destDir + name : destDir + "/" + name
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
        self.destDir = destDir
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = files.map { UploadItem(url: $0, destDir: destDir) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    func start() {
        guard !started else { return }
        started = true
        pendingBaselineReset = true
        Task { await sampleLoop() }
        Task { await runFrom() }
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
        Task { await runFrom() }
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
            let resuming = item.interrupted

            item.state = .checking
            pendingBaselineReset = true
            let probe = await fs.probeUpload(remotePath: item.remotePath)

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
                default: it.state = .cancelled
                }
            }
            phase = .cancelled
        } else {
            phase = .done
        }
        if landedAny { onAllDone() }
    }

    // MARK: 速度采样（0.1s + EMA 平滑；压缩时把"已传压缩字节"映射回原始字节空间）

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
}

// MARK: - 上传弹窗

struct UploadDialog: View {
    @ObservedObject var task: UploadTask
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
            buttons
        }
        .padding(18)
        .frame(width: 480)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 24, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.mauve)
                .frame(width: 30, height: 30)
                .background(Pal.mauve.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("上传文件").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                Text("到 \(task.destDir)")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            statusBadge
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
                ForEach(task.items) { item in UploadRow(item: item) }
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
                pill("续传失败项", fg: Pal.mauve, base: Pal.mauve.opacity(0.14)) { task.retryFailed(resume: true) }
                pill("重试", fg: Pal.subtext, base: Pal.fill(0.07)) { task.retryFailed(resume: false) }
                pill("关闭", fg: Pal.overlay, base: Pal.fill(0.07), action: onClose)
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
        case .uploading: return "arrow.up.circle"
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
