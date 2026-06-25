import AppKit
import SwiftUI

@main
struct TermoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 三栏布局（活动栏 + 主机侧栏 + 工作区）+ 设置/新增主机弹窗(≈720宽) 的合理下限
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        applyAppIcon()
        setupMainMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 自定义中文主菜单：应用菜单只保留「关于」「退出」；保留「编辑」菜单以支持
    /// 输入框/代码编辑器的复制粘贴等（否则这些标准操作会失效）。
    private func setupMainMenu() {
        let main = NSMenu()

        // 应用菜单（标题由系统替换为 App 名）
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = NSMenuItem(title: "关于 Termo", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 Termo",
                                   action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // 编辑菜单（复制/粘贴/撤销等依赖这些菜单项的快捷键注册）
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = main
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            let hosting = NSHostingView(rootView: AboutWindow())
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = "关于 Termo"
            w.isReleasedWhenClosed = false
            w.contentView = hosting
            w.setContentSize(NSSize(width: 420, height: hosting.fittingSize.height))
            w.center()
            aboutWindow = w
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
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
        // 注意：动画必须局限在各自 overlay 的 ZStack 内，不能加在链上——否则会泄漏到
        // 下方的 .sheet 子树，导致 sheet（如测试连接弹窗）内容出现时被错误动画。
        .overlay {
            ZStack {
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
        }
        .overlay {
            ZStack {
                if let h = model.connectingHost {
                    ConnectingDialog(host: h,
                                     verify: { await model.verifyHostKey(h) },
                                     onConnected: { model.finishConnecting() },
                                     onCancel: { model.cancelConnecting() })
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.connectingHost?.id)
        }
        // 指纹验证弹窗叠在连接弹窗之上（未知主机首次连接时需要用户核对）
        .overlay {
            ZStack {
                if let pending = model.pendingHostKey {
                    HostKeyDialog(pending: pending).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.pendingHostKey?.id)
        }
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
