import AppKit
import SwiftUI
import WebKit

// MARK: - 发行说明 WebView（主题化、链接外开）

/// 渲染 appcast 的 HTML 发行说明。注入与当前主题一致的 CSS（背景透明，由外层卡片提供底色），
/// 链接点击走系统浏览器而非在内嵌视图导航。
struct ReleaseNotesWebView: NSViewRepresentable {
    let html: String
    @ObservedObject private var theme = ThemeManager.shared

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")   // 透明，露出卡片底色，避免白闪
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(themedDocument(html), baseURL: nil)
    }

    private func themedDocument(_ body: String) -> String {
        let text = cssHex(Pal.text), sub = cssHex(Pal.subtext)
        let bright = cssHex(Pal.textBright), link = cssHex(Pal.mauve)
        let code = cssHex(Pal.surface0)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
          html,body { background: transparent; margin: 0; padding: 0; }
          body { color: \(text); font: 13px/1.55 -apple-system, "PingFang SC", sans-serif; padding: 2px 4px 8px; }
          h1,h2,h3,h4 { color: \(bright); margin: 0.6em 0 0.35em; font-weight: 600; }
          h1 { font-size: 16px; } h2 { font-size: 15px; } h3 { font-size: 14px; }
          p,li { color: \(text); margin: 0.35em 0; }
          ul,ol { padding-left: 1.3em; margin: 0.35em 0; }
          a { color: \(link); text-decoration: none; }
          a:hover { text-decoration: underline; }
          small, .muted { color: \(sub); }
          code,pre { background: \(code); border-radius: 5px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
          code { padding: 1px 4px; font-size: 12px; }
          pre { padding: 8px 10px; overflow-x: auto; } pre code { background: transparent; padding: 0; }
          hr { border: 0; border-top: 1px solid \(code); margin: 0.8em 0; }
        </style></head><body>\(body)</body></html>
        """
    }

    private func cssHex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - 更新面板（方案 B：统一 ThemedXxx 组件，按状态机渲染）

/// 自动更新面板，宿主于独立窗口（UpdateWindowPresenter）。观察 UpdateController，按 phase 渲染：
/// 检查中 / 已是最新 / 发现新版本(+发行说明) / 下载 / 解压 / 待安装 / 安装中 / 出错。
struct UpdatePanel: View {
    @ObservedObject var controller: UpdateController
    @ObservedObject private var theme = ThemeManager.shared

    // 标题由原生标题栏（窗口 title「软件更新」+ 交通灯）提供，面板本身只渲染内容，
    // 高度全交给系统固定的标题栏，不再随状态切换而跳动（自绘 header + fullSizeContentView 的旧做法会跳）。
    var body: some View {
        content
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(width: 440, alignment: .leading)
            .background(Pal.solidBase)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:        EmptyView()
        case .checking:    checking
        case .upToDate:    upToDate
        case .found:       found
        case .downloading: progressBlock(title: "正在下载更新…", label: controller.progressLabel, fraction: controller.progressFraction, cancellable: true)
        case .extracting:  progressBlock(title: "正在解压更新…", label: "", fraction: controller.progressFraction, cancellable: false)
        case .readyToInstall: ready
        case .installing:  installing
        case .error(let msg): errorBlock(msg)
        }
    }

    // —— 各状态 ——

    private var checking: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("正在检查更新…").font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            SecondaryButton(title: "取消", action: { controller.cancel() })
        }
    }

    private var upToDate: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(Pal.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已是最新版本").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    Text("当前 \(AppInfo.versionLine)").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
            }
            HStack { Spacer(); PrimaryButton(title: "好的", action: { controller.acknowledge() }) }
        }
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("发现新版本").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                    if let i = controller.info, i.isCritical {
                        Text("重要").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Pal.red, in: Capsule())
                    }
                }
                if let i = controller.info {
                    Text("Termo \(i.displayVersion)（build \(i.build)）"
                         + (i.dateString.map { " · \($0)" } ?? ""))
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    Text("当前 \(AppInfo.version)（build \(AppInfo.build)）→ 新 \(i.displayVersion)")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
            }
            releaseNotes
            HStack(spacing: 10) {
                Button(action: { controller.skip() }) {
                    Text("跳过此版本").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer()
                SecondaryButton(title: "稍后", action: { controller.later() })
                PrimaryButton(title: "立即更新", action: { controller.install() })
            }
        }
    }

    @ViewBuilder
    private var releaseNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("更新内容").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
            Group {
                if let html = controller.releaseNotesHTML, !html.isEmpty {
                    ReleaseNotesWebView(html: html)
                } else {
                    Text("本次更新暂无发行说明。")
                        .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
            .frame(height: 200)
            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.fill(0.07), lineWidth: 1))
        }
    }

    private func progressBlock(title: String, label: String, fraction: Double, cancellable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
            ProgressView(value: fraction).tint(Pal.mauve)
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                Spacer()
                if cancellable { SecondaryButton(title: "取消", action: { controller.cancel() }) }
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(Pal.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("更新已就绪").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    Text("将重启 Termo 完成安装").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                SecondaryButton(title: "稍后", action: { controller.later() })
                PrimaryButton(title: "立即重启并安装", action: { controller.install() })
            }
        }
    }

    private var installing: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("正在安装，即将重启…").font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
        }
    }

    private func errorBlock(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18)).foregroundStyle(Pal.red)
                Text("更新失败").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
            }
            Text(msg).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); PrimaryButton(title: "好的", action: { controller.acknowledge() }) }
        }
    }
}

// MARK: - 窗口宿主

/// 用独立窗口承载更新面板：App 隐藏到托盘时仍能弹出。窗口去掉原生关闭键、标题透明，
/// 由面板自绘标题与 ✕，与 ConfirmDialog/AboutWindow 一致的统一观感。
@MainActor
final class UpdateWindowPresenter {
    static let shared = UpdateWindowPresenter()
    private var window: NSWindow?

    /// 显示/刷新面板窗口（apply 每次状态变化都会调到，借此按内容自适应高度）。
    func present() {
        let w = ensureWindow()
        if let host = w.contentView as? NSHostingView<UpdatePanel> {
            w.setContentSize(NSSize(width: 440, height: host.fittingSize.height))
        }
        if !w.isVisible { w.center() }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.orderOut(nil)
    }

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }
        let host = NSHostingView(rootView: UpdatePanel(controller: .shared))
        // 原生标题栏（含交通灯）：标题栏高度由系统固定、内容区在其下方；窗口随状态重算高度时标题栏不跳，
        // 与「关于」窗口同一观感。替代旧的自绘 header + fullSizeContentView（后者会随状态切换而变高）。
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "软件更新"
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(Pal.solidBase)
        w.contentView = host
        w.setContentSize(NSSize(width: 440, height: host.fittingSize.height))
        // 点红灯 / ⌘W 关闭 ≈ 旧的自绘 ✕：通知 controller 收尾（取消进行中的检查、回 idle）。
        // orderOut（dismiss）不触发本通知，故程序化隐藏不会误调。
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { UpdateController.shared.userClosedPanel() }
        }
        window = w
        return w
    }
}
