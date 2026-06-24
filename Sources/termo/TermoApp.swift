import AppKit
import SwiftUI

@main
struct TermoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 480, minHeight: 300)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyAppIcon()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppIcon() {
        let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.module.url(forResource: "AppIcon", withExtension: "png")
        if let url, let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            ActivityBar(model: model)
            Sidebar(model: model)
            // 文件栏特权：允许拖到更宽（深层目录树）；其它区上限 320
            SidebarDivider(width: $model.sidebarWidth, maxWidth: model.section == .files ? 600 : 320)
            VStack(spacing: 0) {
                TabBar(model: model)
                Workspace(model: model)
                    .padding([.leading, .top], 3)
            }
            .background(Pal.mantle)
        }
        .onChange(of: model.section) { sec in
            // 离开文件栏时，若超过常规上限则收回（宽度是文件栏的特权）
            if sec != .files, model.sidebarWidth > 320 {
                withAnimation(.easeOut(duration: 0.2)) { model.sidebarWidth = 320 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.base)
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .overlay {
            if model.pendingCloseTabId != nil {
                ConfirmDialog(
                    title: model.pendingCloseDialogTitle,
                    message: model.pendingCloseDialogMessage,
                    confirmTitle: "关闭",
                    destructive: true,
                    onConfirm: { model.confirmPendingClose() },
                    onCancel: { model.cancelPendingClose() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.pendingCloseTabId)
        .overlay {
            if let h = model.connectingHost {
                ConnectingDialog(host: h,
                                 verify: { await model.verifyHostKey(h) },
                                 onConnected: { model.finishConnecting() },
                                 onCancel: { model.cancelConnecting() })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.connectingHost?.id)
        // 指纹验证弹窗叠在连接弹窗之上（未知主机首次连接时需要用户核对）
        .overlay {
            if let pending = model.pendingHostKey {
                HostKeyDialog(pending: pending).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.pendingHostKey?.id)
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $model.showAddHost) {
            AddHostView(model: model)
        }
        .sheet(item: $model.editingHost) { host in
            AddHostView(model: model, editing: host)
        }
        .sheet(isPresented: $model.showAddRDPHost) {
            AddRDPHostView(model: model)
        }
        .sheet(item: $model.editingRDPHost) { host in
            AddRDPHostView(model: model, editing: host)
        }
        .onAppear { model.applyStartupIfNeeded() }
    }
}

/// 内容铺满到顶（fullSizeContentView + 透明标题栏），并把系统原生红绿灯整体下移，
/// 与标签栏对齐（不再单独占用顶部一行）。下移量由 lightsDownOffset 控制。
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.attach(to: v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var window: NSWindow?
        private var originalY: [ObjectIdentifier: CGFloat] = [:]
        private let lightsDownOffset: CGFloat = 9 // 红绿灯整体下移量

        func attach(to v: NSView, attempt: Int = 0) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let w = v.window else {
                    if attempt < 20 { self.attach(to: v, attempt: attempt + 1) }
                    return
                }
                self.window = w
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.styleMask.insert(.fullSizeContentView)
                // 不修改标题栏容器高度——保持原生红绿灯外观和交互
                NotificationCenter.default.addObserver(self, selector: #selector(self.reposition), name: NSWindow.didResizeNotification, object: w)
                NotificationCenter.default.addObserver(self, selector: #selector(self.reposition), name: NSWindow.didBecomeKeyNotification, object: w)
                self.reposition()
            }
        }

        @objc func reposition() {
            guard let w = window else { return }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { w.standardWindowButton($0) }
            for b in buttons {
                let id = ObjectIdentifier(b)
                if originalY[id] == nil { originalY[id] = b.frame.origin.y }
                b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: originalY[id]! - lightsDownOffset))
            }
        }
    }
}
