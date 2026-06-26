import AppKit
import SwiftUI

/// 进程入口：必须在 `NSApplication` 初始化之前对齐语言。文件选择/保存等系统面板由独立服务渲染，
/// 它沿用进程启动那一刻确定的语言；放到 App.init 里设已太晚。用 bundle 已按系统解析好、剥离地区
/// 后缀的本地化（如把 zh-Hans-GB 归一为 zh-Hans）覆盖 AppleLanguages，让面板跟随系统语言。
@main
enum AppBootstrap {
    static func main() {
        let langs = Bundle.main.preferredLocalizations
        if !langs.isEmpty { UserDefaults.standard.set(langs, forKey: "AppleLanguages") }
        TermoApp.main()
    }
}

struct TermoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 三栏布局（活动栏 + 主机侧栏 + 工作区）与设置/新增主机弹窗(约 720 宽) 的合理下限
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
        _ = OSLogo.fontName   // 预注册随包发行版 Logo 字体(Font Logos)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 自定义中文主菜单：应用菜单只保留「关于」「退出」；保留「编辑」菜单以注册
    /// 输入框/代码编辑器复制粘贴等标准操作的快捷键（否则这些操作会失效）。
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

        // 编辑菜单（复制/粘贴/撤销等快捷键依赖这些菜单项才能注册）
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
    // 侧栏宽度独立成一个对象,拖动它不会牵动 TabBar/Workspace 重算(见 LayoutModel)。
    @StateObject private var layout = LayoutModel()
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            ActivityBar(model: model, layout: layout)
            Sidebar(model: model, tabs: model.tabsModel, layout: layout)
            // 文件栏特权：允许拖到更宽（容纳深层目录树）；其它区上限 320。
            // zIndex(1)：拖动时分隔条会画一条越过工作区的引导线,须盖在工作区之上。
            SidebarDivider(layout: layout, maxWidth: model.section == .files ? 600 : 320)
                .zIndex(1)
            VStack(spacing: 0) {
                TabBar(model: model, tabs: model.tabsModel)
                Workspace(model: model, tabs: model.tabsModel)
                    .padding([.leading, .top], 3)
            }
            .background(Pal.mantle)
        }
        .onChange(of: model.section) { sec in
            // 离开文件栏时，若超过常规上限则收回（额外宽度是文件栏的特权）。
            // 瞬间收回(不加动画):宽度动画会逐帧重排工作区,造成卡顿。
            if sec != .files, layout.sidebarWidth > 320 {
                layout.sidebarWidth = 320
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.base)
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .preferredColorScheme(theme.isDark ? .dark : .light)
        // 注意：动画必须局限在各自 overlay 的 ZStack 内，不能加在视图链上——否则会泄漏到
        // 下方的 .sheet 子树，导致 sheet（如测试连接弹窗）内容出现时被错误地附带动画。
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
        // 指纹验证弹窗叠在连接弹窗之上（未知主机首次连接时需用户核对）
        .overlay {
            ZStack {
                if let pending = model.pendingHostKey {
                    HostKeyDialog(pending: pending).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.pendingHostKey?.id)
        }
        .overlay { fileOpOverlays }
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

    /// 文件栏右键操作的弹窗叠层（合并为单个 overlay，避免 body 内 overlay 链过长导致编译器类型检查超时）。
    @ViewBuilder
    private var fileOpOverlays: some View {
        ZStack {
            if let ctx = model.pendingFileDelete {
                ConfirmDialog(
                    title: "删除「\(ctx.file.name)」？",
                    message: ctx.file.isDir ? "该目录及其全部内容将被永久删除，不可恢复。" : "该文件将被永久删除，不可恢复。",
                    confirmTitle: "删除", destructive: true,
                    onConfirm: { model.confirmFileDelete() },
                    onCancel: { model.pendingFileDelete = nil }
                ).transition(.opacity)
            }
            if let ctx = model.pendingFileRefresh {
                ConfirmDialog(
                    title: "文件有未保存的修改",
                    message: "「\(ctx.fileName)」在编辑器中有未保存的修改。重新加载会丢弃这些修改。",
                    confirmTitle: "重新加载", destructive: true,
                    onConfirm: { model.confirmFileRefreshReload() },
                    onCancel: { model.pendingFileRefresh = nil }
                ).transition(.opacity)
            }
            if let ctx = model.pendingFileRename {
                RenameDialog(
                    originalName: ctx.file.name,
                    onConfirm: { model.confirmFileRename(newName: $0) },
                    onCancel: { model.pendingFileRename = nil }
                ).transition(.opacity)
            }
            if let ctx = model.pendingFileChmod {
                ChmodDialog(
                    fileName: ctx.file.name, initialMode: ctx.mode,
                    onConfirm: { model.confirmFileChmod(mode: $0) },
                    onCancel: { model.pendingFileChmod = nil }
                ).transition(.opacity)
            }
            if let info = model.pendingFileInfo {
                ConfirmDialog(
                    title: info.title, message: info.message,
                    confirmTitle: "好的", showCancel: false,
                    onConfirm: { model.pendingFileInfo = nil },
                    onCancel: { model.pendingFileInfo = nil }
                ).transition(.opacity)
            }
            if let task = model.uploadTask, model.showUploadDialog {
                UploadDialog(task: task,
                             onHide: { model.showUploadDialog = false },
                             onClose: { model.uploadTask = nil; model.showUploadDialog = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.uploadTask?.id)
        .animation(.easeOut(duration: 0.18), value: model.showUploadDialog)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileDelete?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileRename?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileChmod?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileRefresh?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileInfo?.id)
    }
}

/// 内容铺满到顶（fullSizeContentView + 透明标题栏），并把系统原生窗口控制按钮整体下移，
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
        private let lightsDownOffset: CGFloat = 9 // 窗口控制按钮整体下移量

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
                // 不修改标题栏容器高度——保持原生窗口控制按钮的外观和交互
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
