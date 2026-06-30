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
                .pointerCursor()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            ConnectionProgressView(tester: tester, targetLabel: targetLabel)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            // 底部
            HStack {
                Spacer()
                if tester.isRunning {
                    SecondaryButton(title: "取消") { tester.cancel(); dismiss() }
                } else {
                    SecondaryButton(title: "关闭") { dismiss() }
                    PrimaryButton(title: "重新测试") { tester.start(conn: draft.buildConnection()) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 520, height: 600)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            // 用禁用动画的事务填充初始内容，避免内容在 sheet 呈现动画期间「从上滑入」
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { tester.start(conn: draft.buildConnection()) }
        }
        .onDisappear { tester.cancel() }
    }

    private var targetLabel: String {
        let u = draft.user.isEmpty ? "" : "\(draft.user)@"
        return "\(u)\(draft.address):\(draft.port)"
    }
}

/// 可复用的连接进度视图：目标状态 + 步骤 + 实时日志（测试连接与连接终端共用）。
struct ConnectionProgressView: View {
    @ObservedObject var tester: ConnectionTester
    let targetLabel: String
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(tester.overallColor).frame(width: 8, height: 8)
                Text(targetLabel).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                Spacer()
                Text(tester.overallStatusText).font(.system(size: 12, weight: .medium)).foregroundStyle(tester.overallColor)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(tester.steps) { step in stepRow(step) }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("实时日志").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.overlay)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            combinedLog
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("logBottom")
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: tester.logs.count) { _ in
                        // 不加 withAnimation：避免日志增长触发的动画牵动整块内容布局
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(theme.isDark ? Pal.fill(0.03) : Pal.fill(0.02))
        }
    }

    /// 把所有日志拼成单个 Text（保留时间戳与各自配色），支持跨行自由选中复制。
    private var combinedLog: Text {
        tester.logs.reduce(Text(verbatim: "")) { acc, log in
            let stamp = log.time.isEmpty ? "" : log.time + "  "
            return acc
                + Text(verbatim: stamp).foregroundColor(Pal.overlay)
                + Text(verbatim: log.message + "\n").foregroundColor(log.color)
        }
    }

    private func stepRow(_ step: ConnectionStep) -> some View {
        HStack(spacing: 10) {
            stepIcon(step.state).frame(width: 18)
            Text(step.title).font(.system(size: 13))
                .foregroundStyle(step.state == .pending ? Pal.overlay : Pal.text)
            Spacer()
            if let detail = step.detail {
                Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.overlay)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stepIcon(_ state: ConnectionStep.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(Pal.overlay)
        case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
        case .success: Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.green)
        case .failure: Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.red)
        }
    }
}

/// 连接主机时的进度弹窗（复用 ConnectionProgressView），成功后回调进入终端。
struct ConnectingDialog: View {
    let host: Host
    var successHint: String = "正在进入终端…"   // 成功后的提示，按动作变化（终端/文件/转发/监控）
    let verify: () async -> Bool   // 指纹验证（可能弹出指纹核对框）；返回是否继续连接
    let onConnected: () -> Void
    let onCancel: () -> Void
    @StateObject private var tester = ConnectionTester()
    @ObservedObject private var theme = ThemeManager.shared
    @State private var verifying = true
    
    private let dialogCornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("正在连接").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 16)
                Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

                if verifying {
                    verifyingPanel
                } else {
                    ConnectionProgressView(tester: tester, targetLabel: targetLabel)
                }

                Rectangle().fill(Pal.fill(0.06)).frame(height: 1)
                HStack {
                    Spacer()
                    if verifying {
                        SecondaryButton(title: "取消") { onCancel() }
                    } else if tester.isRunning {
                        SecondaryButton(title: "取消") { tester.cancel(); onCancel() }
                    } else if tester.failed {
                        SecondaryButton(title: "取消") { onCancel() }
                        PrimaryButton(title: "重试") { tester.start(conn: host.ssh ?? SSHConnection()) }
                    } else {
                        Text("连接成功，\(successHint)").font(.system(size: 12)).foregroundStyle(Pal.green)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
            }
            .frame(width: 520, height: 560)
            .background(Pal.solidMantle)
            .clipShape(
                RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous)
                    .strokeBorder(Pal.fill(0.08), lineWidth: 1)
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task {
            tester.onFinished = { success in
                guard success else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onConnected() }
            }
            // 第一阶段：验证主机指纹（已知主机瞬间通过；未知主机会叠加指纹核对框）
            let ok = await verify()
            guard !Task.isCancelled else { return }
            if ok {
                verifying = false
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { tester.start(conn: host.ssh ?? SSHConnection()) }
            } else {
                onCancel()
            }
        }
        .onDisappear { tester.cancel() }
    }

    private var verifyingPanel: some View {
        VStack(spacing: 0) {
            // 目标行（与 ConnectionProgressView 顶部一致）
            HStack(spacing: 8) {
                Circle().fill(Pal.yellow).frame(width: 8, height: 8)
                Text(targetLabel)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                Spacer()
                Text("验证中…").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.yellow)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            Spacer()
            VStack(spacing: 14) {
                ProgressView().controlSize(.small)
                Text("正在验证主机指纹…")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var targetLabel: String {
        guard let s = host.ssh else { return host.addr }
        let u = s.user.isEmpty ? "" : "\(s.user)@"
        return "\(u)\(s.host):\(s.port)"
    }
}

// MARK: - 连接测试器（驱动真实 ssh -v，解析输出还原各阶段进度）

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

    private let stepTitles = ["初始化配置", "解析主机地址", "建立 TCP 连接", "SSH 协议握手", "身份验证", "连接成功"]
    private var cancelled = false
    private var concluded = false
    /// C 回调闭包载体（Unmanaged 跨 @convention(c) 边界传递）。
    private final class StageBox {
        let cb: (Int, Bool, String?) -> Void
        init(_ cb: @escaping (Int, Bool, String?) -> Void) { self.cb = cb }
    }
    /// 测试/连接结束时回调一次（true=成功）。
    var onFinished: ((Bool) -> Void)?

    private func conclude(_ success: Bool) {
        guard !concluded else { return }
        concluded = true
        onFinished?(success)
    }

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

    func start(conn: SSHConnection) {
        cancel()
        steps = stepTitles.map { ConnectionStep(title: $0) }
        logs = []
        isRunning = true
        failed = false
        cancelled = false
        concluded = false

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
        markRunning(1)

        // [SSH 迁移] 进程内 libssh2 分阶段测试（替代 spawn ssh -v）：连接由 App 进程发起，
        // 触发 macOS 本地网络权限弹窗，且内网主机不再因子进程发起连接而被静默拦截。
        let isKey = conn.authMethod == .key
        let keyPath: String? = isKey
            ? (conn.keyId.isEmpty ? (conn.keyPath.isEmpty ? nil : conn.keyPath) : KeyMaterializer.path(forKeyId: conn.keyId))
            : nil
        let password: String? = isKey ? nil : conn.password
        let keyPass: String? = isKey ? conn.password : nil
        let (h, p, u) = (conn.host, conn.port, conn.user)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let box = Unmanaged.passRetained(StageBox { stage, ok, msg in
                Task { @MainActor in self?.onStage(stage: stage, ok: ok, message: msg) }
            }).toOpaque()
            termo_ssh_test(h, Int32(p), u, password, keyPath, keyPass, { ud, stage, ok, msg in
                guard let ud else { return }
                let b = Unmanaged<StageBox>.fromOpaque(ud).takeUnretainedValue()
                b.cb(Int(stage), ok != 0, msg.map { String(cString: $0) })
            }, box)
            Unmanaged<StageBox>.fromOpaque(box).release()
        }
    }

    func cancel() {
        cancelled = true   // 后台 libssh2 测试会在超时后自行结束；这里停止后续 UI 更新
        isRunning = false
    }

    /// libssh2 分阶段回调（C stage 1..5 ↔ UI 步骤 1..5）。
    private func onStage(stage: Int, ok: Bool, message: String?) {
        guard isRunning, !cancelled, stage >= 1, stage < steps.count else { return }
        if let message, !message.isEmpty { log(message, color: ok ? Pal.subtext : Pal.red) }
        if ok {
            markSuccess(stage)
            if stage == steps.count - 1 {          // 末阶段「连接成功」
                log("连接成功 ✓", color: Pal.green)
                isRunning = false
                conclude(true)
            } else {
                markRunning(stage + 1)
            }
        } else {
            failStep(stage)                        // 置失败 + 结束（内部 conclude(false)）
        }
    }

    // MARK: - 解析真实 ssh -v 输出

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
        conclude(false)
    }

    private func log(_ message: String, color: Color = Pal.subtext) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        logs.append(ConnectionLog(time: fmt.string(from: Date()), message: message, color: color))
    }
}
