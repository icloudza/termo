import SwiftUI

struct TestConnectionView: View {
    @ObservedObject var draft: HostDraft
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tester = ConnectionTester()

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack {
                Text("测试连接")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 24, height: 24)
                        .background(Pal.fill(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            Divider().overlay(Pal.fill(0.06))

            // 目标信息
            HStack(spacing: 8) {
                statusDot
                Text(targetLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Pal.subtext)
                Spacer()
                Text(tester.overallStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tester.overallColor)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            // 连接流程
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tester.steps) { step in
                    stepRow(step)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider().overlay(Pal.fill(0.06))

            // 实时日志
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("实时日志").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.overlay)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(tester.logs) { log in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(log.time)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Pal.overlay)
                                    Text(log.message)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(log.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                                .id(log.id)
                            }
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: tester.logs.count) { _ in
                        if let last = tester.logs.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(theme.isDark ? Pal.fill(0.03) : Pal.fill(0.02))

            Divider().overlay(Pal.fill(0.06))

            // 底部
            HStack {
                Spacer()
                if tester.isRunning {
                    SecondaryButton(title: "取消") { tester.cancel(); dismiss() }
                } else {
                    SecondaryButton(title: "关闭") { dismiss() }
                    PrimaryButton(title: "重新测试") { tester.start(draft: draft) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 520, height: 600)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { tester.start(draft: draft) }
        .onDisappear { tester.cancel() }
    }

    private var targetLabel: String {
        let u = draft.user.isEmpty ? "" : "\(draft.user)@"
        return "\(u)\(draft.address):\(draft.port)"
    }

    private var statusDot: some View {
        Circle().fill(tester.overallColor).frame(width: 8, height: 8)
    }

    private func stepRow(_ step: ConnectionStep) -> some View {
        HStack(spacing: 10) {
            stepIcon(step.state)
                .frame(width: 18)
            Text(step.title)
                .font(.system(size: 13))
                .foregroundStyle(step.state == .pending ? Pal.overlay : Pal.text)
            Spacer()
            if let detail = step.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Pal.overlay)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stepIcon(_ state: ConnectionStep.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(Pal.overlay)
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .success:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.green)
        case .failure:
            Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.red)
        }
    }
}

// MARK: - 连接测试模拟器

struct ConnectionStep: Identifiable {
    enum State { case pending, running, success, failure }
    let id = UUID()
    let title: String
    var state: State = .pending
    var detail: String? = nil
}

struct ConnectionLog: Identifiable {
    let id = UUID()
    let time: String
    let message: String
    let color: Color
}

@MainActor
final class ConnectionTester: ObservableObject {
    @Published var steps: [ConnectionStep] = []
    @Published var logs: [ConnectionLog] = []
    @Published var isRunning = false
    @Published var failed = false

    private var process: Process?
    private let stepTitles = ["初始化配置", "解析主机地址", "建立 TCP 连接", "SSH 协议握手", "身份验证", "连接成功"]
    private let probeMarker = "TERMO_CONNECT_OK"
    private var sawMarker = false

    var overallStatusText: String {
        if isRunning { return "连接中…" }
        if failed { return "连接失败" }
        if !steps.isEmpty && steps.allSatisfy({ $0.state == .success }) { return "连接成功" }
        return "等待中"
    }

    var overallColor: Color {
        if isRunning { return Pal.yellow }
        if failed { return Pal.red }
        if !steps.isEmpty && steps.allSatisfy({ $0.state == .success }) { return Pal.green }
        return Pal.overlay
    }

    func start(draft: HostDraft) {
        cancel()
        steps = stepTitles.map { ConnectionStep(title: $0) }
        logs = []
        isRunning = true
        failed = false
        sawMarker = false

        let conn = draft.buildConnection()
        guard !conn.host.isEmpty else {
            log("未填写主机地址", color: Pal.red)
            failStep(0); return
        }

        markRunning(0)
        log("开始测试连接到 \(conn.host):\(conn.port)（用户 \(conn.user)）")
        if conn.disableProxy { log("代理：已禁用") }
        else if !conn.proxyURL.isEmpty { log("代理：\(conn.proxyURL)") }
        if !conn.ciphers.isEmpty { log("指定 Cipher：\(conn.ciphers)") }
        if !conn.kexAlgos.isEmpty { log("指定 KEX：\(conn.kexAlgos)") }
        markSuccess(0)

        // 构建真实 ssh -v 命令
        let proc = Process()
        var env = ProcessInfo.processInfo.environment
        let sshArgs = conn.sshArguments(verbose: true) + ["-o", "BatchMode=no", "echo \(probeMarker); uname -a; echo EXIT_$?"]

        if conn.usesPassword, let sshpass = AppModelSSH.sshpassPath() {
            env["SSHPASS"] = conn.password
            proc.executableURL = URL(fileURLWithPath: sshpass)
            proc.arguments = ["-e", "ssh"] + sshArgs
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = sshArgs
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.handleStdout(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.handleVerbose(s) }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in self?.finished(code: p.terminationStatus) }
        }

        do {
            try proc.run()
            process = proc
            markRunning(1)
        } catch {
            log("启动 ssh 失败：\(error.localizedDescription)", color: Pal.red)
            failStep(1)
        }
    }

    func cancel() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        isRunning = false
    }

    // MARK: - 解析真实 ssh -v 输出

    private func handleVerbose(_ chunk: String) {
        for raw in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            let lower = line.lowercased()

            // 过滤太底层的 debug 噪音，保留关键流程
            if line.contains("Connecting to ") {
                markSuccess(1); markRunning(2)
                log(line.replacingOccurrences(of: "debug1: ", with: ""))
            } else if line.contains("Connection established") {
                markSuccess(2); markRunning(3)
                log("TCP 连接已建立")
            } else if line.contains("Remote protocol version") {
                log(line.replacingOccurrences(of: "debug1: ", with: ""))
            } else if lower.contains("kex:") || line.contains("SSH2_MSG_KEXINIT") || line.contains("kex_exchange_identification") {
                markRunning(3)
            } else if line.contains("Server host key:") {
                log(line.replacingOccurrences(of: "debug1: ", with: ""))
            } else if line.contains("Authenticating to") || line.contains("Next authentication method") || line.contains("Offering public key") || line.contains("Trying password") || line.contains("Authentications that can continue") {
                markSuccess(3); markRunning(4)
                log(line.replacingOccurrences(of: "debug1: ", with: ""))
            } else if line.contains("Authentication succeeded") || line.contains("Authenticated to") {
                markSuccess(4); markRunning(5)
                log("身份验证成功", color: Pal.green)
            } else if lower.contains("permission denied") {
                log("身份验证失败：密码或密钥错误", color: Pal.red)
                failStep(4)
            } else if lower.contains("connection refused") {
                log("连接被拒绝（端口未开放？）", color: Pal.red)
                failStep(2)
            } else if lower.contains("connection timed out") || lower.contains("operation timed out") {
                log("连接超时", color: Pal.red)
                failStep(2)
            } else if lower.contains("could not resolve hostname") || lower.contains("name or service not known") {
                log("无法解析主机地址", color: Pal.red)
                failStep(1)
            }
        }
    }

    private func handleStdout(_ chunk: String) {
        for raw in chunk.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.contains(probeMarker) {
                sawMarker = true
                markSuccess(4); markRunning(5)
            } else if !line.isEmpty && !line.hasPrefix("EXIT_") {
                log("远程：\(line)", color: Pal.text)
            }
        }
    }

    private func finished(code: Int32) {
        if sawMarker || code == 0 {
            markSuccess(5)
            log("连接测试通过 ✓", color: Pal.green)
            failed = false
        } else if !failed {
            failedCurrentStep()
            log("连接失败（ssh 退出码 \(code)）", color: Pal.red)
        }
        isRunning = false
    }

    // MARK: - 步骤状态

    private func markRunning(_ i: Int) {
        guard i < steps.count, steps[i].state == .pending else { return }
        steps[i].state = .running
    }
    private func markSuccess(_ i: Int) {
        guard i < steps.count, steps[i].state != .success else { return }
        steps[i].state = .success
    }
    private func failStep(_ i: Int) {
        guard i < steps.count else { return }
        steps[i].state = .failure
        failed = true
        isRunning = false
        cancel()
    }
    private func failedCurrentStep() {
        if let idx = steps.firstIndex(where: { $0.state == .running || $0.state == .pending }) {
            steps[idx].state = .failure
        }
        failed = true
    }

    private func log(_ message: String, color: Color = Pal.subtext) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        logs.append(ConnectionLog(time: fmt.string(from: Date()), message: message, color: color))
    }
}

/// 供 ConnectionTester 复用的 sshpass 查找（避免依赖 @MainActor AppModel 实例）。
enum AppModelSSH {
    static func sshpassPath() -> String? {
        for p in ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass", "/usr/bin/sshpass"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }
}
