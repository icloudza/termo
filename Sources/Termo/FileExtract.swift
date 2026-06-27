import SwiftUI

// MARK: - 归档类型

/// 受支持的压缩包/压缩文件类型。多文件归档默认解压到「同名新文件夹」，单文件压缩默认解压到「当前目录」。
enum ArchiveKind: Equatable {
    case tarGz, tarBz2, tarXz, tarZst, tar, zip, sevenZip, rar   // 多文件归档
    case gz, bz2, xz, zst                                        // 单文件压缩

    /// 按文件名后缀识别（复合后缀如 .tar.gz 优先于 .gz）；非归档返回 nil，用于决定是否显示「解压」菜单。
    static func detect(_ name: String) -> ArchiveKind? {
        let n = name.lowercased()
        func ends(_ s: String) -> Bool { n.hasSuffix(s) }
        if ends(".tar.gz")  || ends(".tgz")  { return .tarGz }
        if ends(".tar.bz2") || ends(".tbz2") || ends(".tbz") { return .tarBz2 }
        if ends(".tar.xz")  || ends(".txz")  { return .tarXz }
        if ends(".tar.zst") || ends(".tzst") { return .tarZst }
        if ends(".tar")  { return .tar }
        if ends(".zip")  { return .zip }
        if ends(".7z")   { return .sevenZip }
        if ends(".rar")  { return .rar }
        if ends(".gz")   { return .gz }
        if ends(".bz2")  { return .bz2 }
        if ends(".xz")   { return .xz }
        if ends(".zst")  { return .zst }
        return nil
    }

    /// 多文件归档（决定默认是否解压到新文件夹）。
    var isMultiFile: Bool {
        switch self {
        case .gz, .bz2, .xz, .zst: return false
        default: return true
        }
    }

    /// 解压所需的远端命令；缺失时给出可读提示。
    var tool: String {
        switch self {
        case .tarGz, .tarBz2, .tarXz, .tarZst, .tar: return "tar"
        case .zip: return "unzip"
        case .sevenZip: return "7z"
        case .rar: return "unrar"
        case .gz: return "gzip"
        case .bz2: return "bzip2"
        case .xz: return "xz"
        case .zst: return "zstd"
        }
    }

    /// 去掉归档后缀得到基名（新建文件夹名 / 单文件解压后的文件名）。
    func baseName(_ name: String) -> String {
        let suffixes = [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz",
                        ".tar.zst", ".tzst", ".tar", ".zip", ".7z", ".rar", ".gz", ".bz2", ".xz", ".zst"]
        let lower = name.lowercased()
        for s in suffixes where lower.hasSuffix(s) { return String(name.dropLast(s.count)) }
        return name
    }
}

// MARK: - 解压任务

enum ExtractPhase: Equatable { case ready, running, done, failed(String) }

/// 单个解压任务：在目标主机上经多路复用 ssh 跑一条 tar/unzip 等命令，完成后局部刷新并发系统通知。
/// 解压无逐字节进度（命令侧不易获取），故用「运行中」转盘 + 完成/失败态，而非进度条；可后台运行。
@MainActor
final class ExtractTask: ObservableObject {
    nonisolated let id = UUID()
    let archive: RemoteFile
    let kind: ArchiveKind
    let parentDir: String          // 归档所在目录（解压产物落此层）
    let folderName: String         // 同名新文件夹 / 单文件解压后的文件名
    // 所属主机（用于后台中控按主机分组；创建后即设，仅展示用）
    var hostId: String? = nil
    var hostName: String = ""

    @Published var phase: ExtractPhase = .ready
    @Published var toSubfolder: Bool   // 解压到同名新文件夹（否则当前目录）

    private let fs: RemoteFS
    private let onDone: () -> Void

    init(archive: RemoteFile, kind: ArchiveKind, parentDir: String,
         fs: RemoteFS, onDone: @escaping () -> Void) {
        self.archive = archive
        self.kind = kind
        self.parentDir = parentDir
        self.folderName = kind.baseName(archive.name)
        self.fs = fs
        self.onDone = onDone
        self.toSubfolder = kind.isMultiFile
    }

    /// 实际解压目标目录。
    var destDir: String {
        toSubfolder ? childPath(parentDir, folderName) : parentDir
    }

    func begin() {
        guard phase == .ready else { return }
        phase = .running
        let cmd = remoteCommand()
        let fs = self.fs
        Task { @MainActor in
            let r = await fs.run(cmd, timeout: 1800)
            if r.code == 0 {
                phase = .done
                Notifier.notify(title: "解压完成", body: "\(archive.name) → \(destDir)")
                onDone()
            } else {
                let err = String(data: r.stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                phase = .failed(err.isEmpty ? "解压失败（退出码 \(r.code)）" : err)
                Notifier.notify(title: "解压失败", body: archive.name)
            }
        }
    }

    func retry() {
        guard case .failed = phase else { return }
        phase = .ready
        begin()
    }

    private func childPath(_ dir: String, _ name: String) -> String {
        (dir == "/" ? "" : dir) + "/" + name
    }

    /// 构造远端解压命令：路径全部经 base64 还原后用双引号引用，杜绝空格/特殊字符与注入问题。
    /// 先校验所需命令存在，再 mkdir -p 目标目录，最后按类型解压。
    private func remoteCommand() -> String {
        let aB64 = Data(archive.path.utf8).base64EncodedString()
        let dB64 = Data(destDir.utf8).base64EncodedString()
        let head = "A=$(printf %s '\(aB64)'|base64 -d); D=$(printf %s '\(dB64)'|base64 -d); "
        let check = "command -v \(kind.tool) >/dev/null 2>&1 || { echo '远端缺少 \(kind.tool) 命令' >&2; exit 127; }; "
        let mk = "mkdir -p -- \"$D\" && "

        switch kind {
        case .tarGz:    return head + check + mk + "tar -xzf \"$A\" -C \"$D\""
        case .tarBz2:   return head + check + mk + "tar -xjf \"$A\" -C \"$D\""
        case .tarXz:    return head + check + mk + "tar -xJf \"$A\" -C \"$D\""
        case .tarZst:   return head + check + mk + "tar --use-compress-program=unzstd -xf \"$A\" -C \"$D\""
        case .tar:      return head + check + mk + "tar -xf \"$A\" -C \"$D\""
        case .zip:      return head + check + mk + "unzip -o \"$A\" -d \"$D\""
        case .sevenZip: return head + check + mk + "7z x -y -o\"$D\" \"$A\""
        case .rar:      return head + check + mk + "unrar x -o+ \"$A\" \"$D/\""
        case .gz, .bz2, .xz, .zst:
            let sB64 = Data(folderName.utf8).base64EncodedString()
            let s = "S=$(printf %s '\(sB64)'|base64 -d); "
            let dec: String
            switch kind {
            case .gz:  dec = "gzip -dc -- \"$A\""
            case .bz2: dec = "bzip2 -dc -- \"$A\""
            case .xz:  dec = "xz -dc -- \"$A\""
            default:   dec = "zstd -dc -- \"$A\""
            }
            return head + s + check + mk + "\(dec) > \"$D/$S\""
        }
    }
}

// MARK: - 解压弹窗

/// 解压弹窗：选目标（同名新文件夹 / 当前目录）→ 运行转盘 → 完成/失败。样式与上传弹窗一致，可后台运行。
struct ExtractDialog: View {
    @ObservedObject var task: ExtractTask
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
            archiveRow
            stageView(task.phase)
            buttons
        }
        .padding(18)
        .frame(width: 420)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(theme.isDark ? 0.40 : 0.14), radius: 24, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Pal.mauve)
                .frame(width: 30, height: 30)
                .background(Pal.mauve.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("解压").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                Text("在 \(task.parentDir)")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            statusBadge
            if task.phase == .running {
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
    }

    @ViewBuilder private var statusBadge: some View {
        let (label, fg): (String, Color) = {
            switch task.phase {
            case .ready:     return ("待解压", Pal.overlay)
            case .running:   return ("解压中", Pal.mauve)
            case .done:      return ("完成", Pal.green)
            case .failed:    return ("失败", Pal.red)
            }
        }()
        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(fg.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }

    private var archiveRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.zipper").font(.system(size: 11)).foregroundStyle(Pal.subtext).frame(width: 14)
            Text(task.archive.name)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.06), lineWidth: 1))
    }

    @ViewBuilder private func stageView(_ phase: ExtractPhase) -> some View {
        switch phase {
        case .ready:          destinationPicker
        case .running:        statusLine(icon: nil, "正在解压…", color: Pal.mauve)
        case .done:           statusLine(icon: "checkmark.circle.fill", "已解压到 \(task.destDir)", color: Pal.green)
        case .failed(let m):  failed(m)
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("解压到").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            HStack(spacing: 8) {
                destOption("新文件夹「\(task.folderName)」", selected: task.toSubfolder) { task.toSubfolder = true }
                destOption("当前目录", selected: !task.toSubfolder) { task.toSubfolder = false }
                Spacer(minLength: 0)
            }
            Text(task.destDir)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func destOption(_ title: String, selected: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Pal.mauve : Pal.subtext)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Pal.mauve.opacity(0.14) : Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Pal.mauve.opacity(0.4) : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func statusLine(icon: String?, _ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Pal.red)
                Text("解压失败").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                Spacer(minLength: 0)
            }
            Text(message)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(10)
        .background(Pal.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.red.opacity(0.18), lineWidth: 1))
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            switch task.phase {
            case .ready:
                SecondaryButton(title: "取消", action: onClose)
                PrimaryButton(title: "解压") { task.begin() }
            case .running:
                SecondaryButton(title: "后台运行", action: onHide)
            case .done:
                PrimaryButton(title: "完成", action: onClose)
            case .failed:
                SecondaryButton(title: "关闭", action: onClose)
                PrimaryButton(title: "重试") { task.retry() }
            }
        }
    }
}

// 后台解压状态已并入左下角「后台任务」统一中控（见 BackgroundCenterView）。
