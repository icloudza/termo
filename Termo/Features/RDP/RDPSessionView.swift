import SwiftUI

/// RDP 远程桌面标签页：显示 FreeRDP 实时帧。连接进度与证书信任由 ContentView 级的 RDPConnectingDialog 呈现（标签未开即弹）。
struct RDPSessionView: View {
    @ObservedObject var session: RDPSession

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = session.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.low)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    RDPMouseLayer(remoteW: img.width, remoteH: img.height,
                                  onMove: { session.sendMouseMove($0, $1) },
                                  onButton: { session.sendMouseButton($0, down: $1, x: $2, y: $3) },
                                  onWheel: { session.sendMouseWheel($0, x: $1, y: $2) },
                                  onKey: { session.sendKey($0, down: $1) },
                                  onFlags: { session.sendModifiers($0) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 会话通常在标签打开前已连好（连接弹窗阶段）。出现时按真实标签尺寸校正分辨率（连接时用的是估算画布）；
            // 若尚未连接（直接进入此视图的兜底路径）则按尺寸发起连接。
            .onAppear {
                connectIfReady(geo.size)
                session.requestResize(canvas: geo.size)
            }
            .onChange(of: geo.size) { _, new in
                connectIfReady(new)                 // 兜底：未连接则按尺寸连接
                session.requestResize(canvas: new)  // 拖停后合并发一次远端 resize
            }
        }
        // 不在 onDisappear 断开：切换标签会移出本视图，但会话由 model 持有需后台保活（同终端 PTY）。
        // 真正的断开在标签关闭（AppModel 清理 rdpSessions）与新窗口关闭（windowWillClose）时进行。
    }

    private func connectIfReady(_ size: CGSize) {
        guard size.width > 200, size.height > 200 else { return }
        session.connect(canvas: size)
    }
}

/// RDP 连接弹窗：整窗半透明遮罩 + 居中卡片。挂在 ContentView 级、覆盖当前概览/列表，
/// 由「标签未开的连接中会话」驱动：首帧到达即视为成功 → 回调开标签（把已连会话交给标签，无缝切到桌面）。
/// 有证书待确认时改显证书信任框（与连接卡互斥，避免双层遮罩）。
struct RDPConnectingDialog: View {
    @ObservedObject var session: RDPSession
    let onConnected: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            if let prompt = session.certPrompt {
                RDPCertDialog(prompt: prompt).transition(.opacity)
            } else {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    RDPConnectingPanel(session: session, onCancel: onCancel, onRetry: { session.retry() })
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: session.certPrompt?.id)
        // 等首帧沉降完成（整桌面画好）再开标签/窗口，进入更顺、不闪半成品画面。
        .onChange(of: session.ready) { isReady in
            if isReady { onConnected() }
        }
    }
}

/// 连接成功后的打开方式选择弹窗：内嵌标签 还是 新窗口，可勾选记住（写入设置默认）。
struct RDPOpenDialog: View {
    let hostName: String
    let onChoose: (_ window: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void
    @State private var remember = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text("打开远程桌面").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("「\(hostName)」要如何打开？")
                    .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: remember) { remember.toggle() }
                    Text("记住我的选择（可在设置中修改）")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { remember.toggle() }
                }
                HStack(spacing: 10) {
                    SecondaryButton(title: "取消", action: onCancel)
                    Spacer()
                    SecondaryButton(title: "新窗口") { onChoose(true, remember) }
                    PrimaryButton(title: "内嵌标签") { onChoose(false, remember) }
                }
            }
            .padding(20)
            .frame(width: 400)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}

/// 连接进度卡（RDPConnectingDialog 内居中）：目标行 + 三步进度 + 实时日志。
/// 连上出帧后随弹窗隐藏；「取消」始终可用，失败/断开时额外提供「重试」。
private struct RDPConnectingPanel: View {
    @ObservedObject var session: RDPSession
    let onCancel: () -> Void
    let onRetry: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    private var cfg: RDPConnection { session.config }
    private var target: String { "\(cfg.user)@\(cfg.host):\(cfg.port)" }

    private var ended: Bool {   // 失败或断开：额外显示「重试」（取消始终在）
        switch session.phase { case .failed, .disconnected: return true; default: return false }
    }

    private var statusColor: Color {
        switch session.phase {
        case .pending, .connecting: return Pal.yellow
        case .connected: return Pal.green
        case .failed, .disconnected: return Pal.red
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("正在连接").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            // 目标行 + 总状态
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(target).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                Spacer()
                Text(session.connectStatusText).font(.system(size: 12, weight: .medium)).foregroundStyle(statusColor)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            // 步骤
            VStack(alignment: .leading, spacing: 0) {
                ForEach(session.connectSteps) { stepRow($0) }
            }
            .padding(.horizontal, 20).padding(.bottom, 12)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            // 实时日志
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("实时日志").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.overlay)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            logText
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("logBottom")
                        }
                        .padding(.horizontal, 20).padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: session.logs.count) { _ in proxy.scrollTo("logBottom", anchor: .bottom) }
                }
            }
            .frame(height: 150)
            .background(theme.isDark ? Pal.fill(0.03) : Pal.fill(0.02))

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            HStack(spacing: 10) {
                Spacer()
                SecondaryButton(title: "取消") { onCancel() }   // 取消始终可用
                if ended {
                    PrimaryButton(title: "重试") { onRetry() }   // 失败/断开时额外给重试
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 480)
        .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    /// 所有日志拼成单个 Text（保留时间戳与按级别配色），支持跨行选中复制。
    private var logText: Text {
        session.logs.reduce(Text(verbatim: "")) { acc, line in
            let stamp = line.time.isEmpty ? "" : line.time + "  "
            let color: Color = line.level >= 2 ? Pal.red : (line.level == 1 ? Pal.yellow : Pal.subtext)
            return acc
                + Text(verbatim: stamp).foregroundColor(Pal.overlay)
                + Text(verbatim: line.message + "\n").foregroundColor(color)
        }
    }

    private func stepRow(_ step: RDPConnectStep) -> some View {
        HStack(spacing: 10) {
            stepIcon(step.state).frame(width: 18)
            Text(step.title).font(.system(size: 13))
                .foregroundStyle(step.state == .pending ? Pal.overlay : Pal.text)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func stepIcon(_ state: RDPConnectStep.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(Pal.overlay)
        case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
        case .success: Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.green)
        case .failure: Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(Pal.red)
        }
    }
}
