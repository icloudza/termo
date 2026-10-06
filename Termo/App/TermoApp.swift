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
        // 单窗口场景（Window 而非 WindowGroup）：全进程只允许一个窗口实例，从根上杜绝
        // 隐藏到托盘后经启动台/托盘「显示」/⌘N 等路径重复新建窗口；也不再出现「新建窗口」菜单项。
        Window("Termo", id: "main") {
            ContentView()
                // 三栏布局（活动栏 + 主机侧栏 + 工作区）与设置/新增主机弹窗(约 720 宽) 的合理下限
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        // 首次打开的默认尺寸（仅初始值，最小限制不变；用户拖动后由系统记忆）：给三栏 + 工作区更宽裕的空间。
        .defaultSize(width: 1200, height: 800)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var aboutWindow: NSWindow?
    private var tray: TrayController?
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先对齐 AppKit 外观，使窗口首帧即正确明暗，杜绝冷启动露出系统默认浅色窗口底的白闪。
        NSApp.appearance = NSAppearance(named: ThemeManager.shared.isDark ? .darkAqua : .aqua)
        NSApp.setActivationPolicy(.regular)
        applyAppIcon()
        setupMainMenu()
        EditShortcuts.install()
        _ = OSLogo.fontName   // 预注册随包发行版 Logo 字体(Font Logos)
        _ = AppModel.shared   // 提前建好单例，使托盘/退出流程在窗口之外也能访问后台任务
        Notifier.requestAuthIfNeeded()   // 申请系统通知权限（上传/下载完成提醒）
        tray = TrayController(onShow: { [weak self] in self?.showMainWindow() },
                              onQuit: { [weak self] in self?.forceQuit() })
        UpdateController.shared.startup()   // 启动自动更新调度（Dev ID 走 Sparkle；MAS 无操作）
        NSApp.activate(ignoringOtherApps: true)
        // 窗口此刻已创建；记录主窗口并接管其关闭行为（隐藏到托盘）。延迟一拍确保 WindowGroup 已出窗口。
        DispatchQueue.main.async { [weak self] in self?.attachMainWindow() }
    }

    private func attachMainWindow() {
        guard mainWindow == nil else { return }
        // 主窗口 = 可成为主窗口、有内容视图的那个；canBecomeMain 排除托盘 NSStatusBarWindow 与面板，
        // 避免误把状态栏图标窗口当成主窗口（关于窗口/Tooltip 面板此刻尚未创建）。
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }) {
            mainWindow = w
            w.delegate = self
            // 最小化 / 隐藏到菜单栏 / 切到别的桌面 / 被完全遮住时视图收不到 onDisappear：按窗口可见性暂停监控采样。
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main
            ) { [weak w] _ in
                guard let w else { return }
                MainActor.assumeIsolated { AppModel.shared.mainWindowVisibilityChanged(w.occlusionState.contains(.visible)) }
            }
        }
    }
    private var occlusionObserver: NSObjectProtocol?

    /// 从托盘恢复：切回常规激活策略（恢复 Dock 图标与主菜单），前置并激活主窗口。
    /// 现场重新解析窗口（orderOut 后窗口仍在 NSApp.windows 列表中），不依赖可能过期的 mainWindow。
    /// 托盘图标常驻、从不被 orderOut，故无需在此唤回（参见 hideToTray 的窗口过滤说明）。
    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        let w = mainWindow ?? NSApp.windows.first { $0.canBecomeMain && $0.contentView != nil }
        if mainWindow == nil, let w { mainWindow = w; w.delegate = self }
        w?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyAppIcon()   // .accessory→.regular 重建 Dock 图标时系统会重解析，需重新断言，否则回落为通用「exec」占位图标
    }

    /// 点击 Dock/启动台图标重新打开：隐藏到托盘后窗口只是 orderOut（仍存在），此时无可见窗口，
    /// WindowGroup 默认会新建一个 → 同进程出现两个相同窗口。这里复用已存在的窗口并返回 false 阻止新建。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }   // 已有可见窗口：交系统默认前置，不新建
        // 无可见窗口：若隐藏中的主窗口仍在，复用它；否则放行默认新建。
        if NSApp.windows.contains(where: { $0.canBecomeMain && $0.contentView != nil }) {
            showMainWindow()
            return false
        }
        return true
    }

    /// 关闭主窗口：
    /// - 开启「隐藏到托盘」：隐藏窗口 + 切附件模式（仅留菜单栏图标），不退出。
    /// - 否则：视为退出软件，交给退出流程（含后台任务检查）。一律返回 false 不真正关窗——
    ///   这样用户在确认弹窗里选「取消」时窗口得以保留，不会陷入「无窗口但仍在运行」的状态。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == mainWindow else { return true }
        if AppSettings.shared.closeToTray {
            hideToTray()
        } else {
            requestQuit()   // 走退出流程（含后台任务确认）；取消时窗口因返回 false 得以保留
        }
        return false
    }

    /// 隐藏到菜单栏：隐藏所有可见内容窗口、切附件模式。后台任务继续运行，托盘图标常驻不动。
    /// 关键：仅 orderOut `canBecomeMain` 的窗口（主窗口/关于窗口），**放过托盘图标的宿主窗口
    /// NSStatusBarWindow**（其 canBecomeMain==false）。此前用 `!(w is NSPanel) && contentView != nil`
    /// 过滤会连带把 NSStatusBarWindow 也 orderOut——macOS 15 不会自动救回，导致托盘图标消失。
    /// 既然图标窗口从不被隐藏、状态项也从不重建，位置与可见性天然保留，无需任何唤回/重建。
    @MainActor private func hideToTray() {
        // 先关掉所有 sheet + 结束附着 sheet：打开过设置页后其 sheet 宿主窗口可能残留在 NSApp.windows 且仍
        // isVisible（canBecomeMain==false，被旧的 canBecomeMain 过滤漏掉）→ 切 .accessory 时仍有可见窗口，
        // 导致 Dock 图标不消失。故 orderOut 除托盘状态栏窗口（NSStatusBarWindow，常驻不可动）外的所有可见窗口。
        AppModel.shared.dismissAllSheets()
        for w in NSApp.windows { if let s = w.attachedSheet { w.endSheet(s) } }
        for w in NSApp.windows where w.isVisible && !w.className.contains("NSStatusBar") {
            w.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// 关窗 / 菜单退出（⌘Q）入口。本方法为自定义（非协议方法，故不自动 @MainActor），访问 @MainActor 的
    /// AppModel 需显式跳主线程；从 AppKit 主线程回调进来，跳转即时，不影响交互。
    /// - 开启「关闭隐藏到菜单栏」：有后台任务 → 直接隐藏保活（不再弹确认）；无任务 → 直接退出。
    /// - 未开启：弹自定义确认（含「隐藏到菜单栏」选项；有任务时优先展示任务警告与列表）。
    /// 真正彻底退出走托盘菜单的「退出 Termo」（forceQuit），不受本设置影响。
    @objc func requestQuit() {
        Task { @MainActor in
            AppModel.shared.dismissAllSheets()   // 先关掉打开的 sheet：否则退出确认弹窗被盖住、或 sheet 模态阻塞退出
            if AppSettings.shared.closeToTray {
                if AppModel.shared.hasRunningBackground {
                    self.hideToTray()        // 有后台任务：隐藏保活，不打断、不弹窗
                } else if !AppModel.shared.unsavedEditorNames.isEmpty {
                    self.showMainWindow()    // 有未保存的文件：确认后再退出，不能一键丢掉修改
                    AppModel.shared.pendingQuitForce = true
                    AppModel.shared.pendingQuitConfirm = true
                } else {
                    NSApp.terminate(nil)     // 无任务：直接退出
                }
            } else {
                self.showMainWindow()
                AppModel.shared.pendingQuitForce = false   // 关窗/⌘Q 的常规确认（可选隐藏到菜单栏）
                AppModel.shared.pendingQuitConfirm = true
            }
        }
    }

    /// 托盘「退出 Termo」：显式彻底退出，忽略「关闭隐藏到菜单栏」设置。
    /// 有后台任务则弹「停止任务并退出」确认（确认即停任务退出，不再变成隐藏），无任务直接退出。
    @objc func forceQuit() {
        Task { @MainActor in
            AppModel.shared.dismissAllSheets()   // 同上：避免退出确认弹窗被 sheet 盖住
            if AppModel.shared.hasRunningBackground || !AppModel.shared.unsavedEditorNames.isEmpty {
                self.showMainWindow()
                AppModel.shared.pendingQuitForce = true    // 彻底退出模式：确认即退出
                AppModel.shared.pendingQuitConfirm = true
            } else {
                NSApp.terminate(nil)
            }
        }
    }


    // 自定义弹窗已在退出前做后台任务检查（见 requestQuit / QuitConfirmDialog）。
    // 系统发起的退出（注销/关机）会直接走到这里：放行退出，残留隧道由 willTerminate 的进程登记表兜底清理。
    /// 用户已在退出确认里明确选择退出（含放弃未保存的修改）。
    static var quitConfirmed = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 程序坞「退出」、自动更新重启、AppleScript 等走 NSApp.terminate 的路径也要先问未保存的文件；
        // 注销、关机由系统发起，不拦。
        if !Self.quitConfirmed, !Self.isSystemQuit, !AppModel.shared.unsavedEditorNames.isEmpty {
            showMainWindow()
            AppModel.shared.pendingQuitForce = true
            AppModel.shared.pendingQuitConfirm = true
            return .terminateCancel
        }
        // 收口所有退出路径的清理：结束附着 sheet、复位 SwiftUI 绑定、关闭 RDP（join FreeRDP 线程）、优雅停端口转发。
        for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } }
        AppModel.shared.dismissAllSheets()
        AppModel.shared.shutdownAllRDP()
        ForwardProcessRegistry.shared.terminateAll()
        UserDefaults.standard.synchronize()
        // 关键：打开过设置页等会拉起 RemoteViewService（进程外视图）的界面后，系统在 exit() 的 atexit 阶段会卡在
        // CoreAnalytics 退出屏障（sendExitBarrierWithTimeoutSync 同步等该 XPC flush），进程迟迟不退、被系统升级为
        // SIGTERM（表现为「开着设置页从 Dock 退不掉/报错」）。清理已完成、数据均即时落盘，这里直接 _exit 立即结束
        // 进程绕过该屏障；不返回。
        _exit(0)
    }

    private static var isSystemQuit: Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent,
              let reason = ev.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        let system: [OSType] = [OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAEShowRestartDialog),
                                OSType(kAEShowShutdownDialog), OSType(kAERestart), OSType(kAEShutDown)]
        return system.contains(reason)
    }

    private var mainMenu: NSMenu?
    private var menuObservers: [NSObjectProtocol] = []

    /// 自定义中文主菜单：应用菜单只保留「关于」「设置」「退出」；「编辑」菜单注册复制粘贴等标准操作的快捷键，
    /// 「标签」菜单实现设置页「快捷键」里列出的全局快捷键。
    private func setupMainMenu() {
        let main = buildMainMenu()
        mainMenu = main
        NSApp.mainMenu = main
        // 主菜单归 SwiftUI 管理，窗口切换等时机可能被换成它生成的默认菜单（快捷键随之失效）：被换掉就装回来。
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
            menuObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, let menu = self.mainMenu, NSApp.mainMenu !== menu else { return }
                NSApp.mainMenu = menu
            })
        }
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        // 应用菜单（标题由系统替换为 App 名）
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = NSMenuItem(title: String(localized: "关于 Termo"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let checkUpdate = NSMenuItem(title: String(localized: "检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdate.target = self
        appMenu.addItem(checkUpdate)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        // 系统标准项：⌘H / ⌥⌘H 是所有 Mac App 都应响应的。目标留空，由 NSApplication 处理。
        appMenu.addItem(NSMenuItem(title: String(localized: "隐藏 Termo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: String(localized: "隐藏其他"),
                                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: String(localized: "全部显示"),
                                   action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "退出 Termo"), action: #selector(requestQuit), keyEquivalent: "q")
        quit.target = self   // 经退出流程检查后台任务，而非直接 terminate
        appMenu.addItem(quit)

        // 编辑菜单：复制/粘贴/撤销等标准操作依赖这些菜单项把快捷键注册到响应链才生效（输入框/编辑器/sheet 内同理）。
        // 父项必须有标题，否则菜单栏显示为空；每项显式设 keyEquivalentModifierMask = ⌘（与代码库其它菜单一致），
        // 避免默认修饰键在自定义主菜单下未被识别导致 ⌘X/⌘C/⌘V/⌘A 失效。
        let editItem = NSMenuItem()
        editItem.title = String(localized: "编辑")
        main.addItem(editItem)
        let edit = NSMenu(title: String(localized: "编辑"))
        editItem.submenu = edit
        func addEdit(_ title: String, _ action: Selector, _ key: String,
                     _ mask: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            edit.addItem(item)
        }
        addEdit(String(localized: "撤销"), Selector(("undo:")), "z")
        addEdit(String(localized: "重做"), Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        addEdit(String(localized: "剪切"), #selector(NSText.cut(_:)), "x")
        addEdit(String(localized: "复制"), #selector(NSText.copy(_:)), "c")
        addEdit(String(localized: "粘贴"), #selector(NSText.paste(_:)), "v")
        addEdit(String(localized: "全选"), #selector(NSText.selectAll(_:)), "a")

        let tabItem = NSMenuItem()
        tabItem.title = String(localized: "标签")
        main.addItem(tabItem)
        let tabMenu = NSMenu(title: String(localized: "标签"))
        tabItem.submenu = tabMenu
        @discardableResult
        func addTab(_ title: String, _ action: Selector, _ key: String,
                    _ mask: NSEvent.ModifierFlags = .command, hidden: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = self
            if hidden { item.isHidden = true; item.allowsKeyEquivalentWhenHidden = true }
            tabMenu.addItem(item)
            return item
        }
        addTab(String(localized: "新建终端"), #selector(newTerminal), "t")
        addTab(String(localized: "关闭标签"), #selector(closeTab), "w")
        tabMenu.addItem(.separator())
        addTab(String(localized: "下一个标签"), #selector(nextTab), "\t", .control)
        addTab(String(localized: "上一个标签"), #selector(previousTab), "\t", [.control, .shift])
        tabMenu.addItem(.separator())
        addTab(String(localized: "切换侧栏"), #selector(toggleSidebar), "b")
        tabMenu.addItem(.separator())
        addTab(String(localized: "放大字体"), #selector(increaseFont), "+")
        addTab(String(localized: "放大字体"), #selector(increaseFont), "=", hidden: true)   // 美式键盘 ⌘+ 实为 ⌘=
        addTab(String(localized: "缩小字体"), #selector(decreaseFont), "-")
        // ⌘1–⌘8 选第 n 个标签，⌘9 选最后一个（同浏览器 / Xcode）。不占菜单位置。
        for n in 1...9 {
            addTab(String(localized: "选择标签 \(n)"), #selector(selectTabNumber(_:)), "\(n)", hidden: true).tag = n
        }

        // 窗口菜单：最小化 / 缩放 / 全屏。目标留空，走 key 窗口的响应链。
        let windowItem = NSMenuItem()
        windowItem.title = String(localized: "窗口")
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: String(localized: "窗口"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: String(localized: "最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: String(localized: "缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: String(localized: "进入全屏幕"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(fullScreen)
        NSApp.windowsMenu = windowMenu

        return main
    }

    @objc private func selectTabNumber(_ sender: NSMenuItem) {
        let n = sender.tag
        withMainWindowModel { model in
            let tabs = model.tabs
            guard !tabs.isEmpty else { return }
            let i = n == 9 ? tabs.count - 1 : n - 1
            guard tabs.indices.contains(i) else { return }
            model.selectTab(tabs[i].id)
        }
    }

    @objc private func showSettings() {
        // 已有弹窗时不再叠开设置：设置在最底层，会被压在可见弹窗下面，且 Esc 会先关掉它而不是眼前的弹窗。
        MainActor.assumeIsolated {
            guard !AppModel.shared.isModalPresented else { return }
            AppModel.shared.showSettings = true
        }
    }

    /// 远程桌面在用键盘时（RDP 独立窗口为 key，或内嵌 RDP 画面为第一响应者），App 自己的快捷键一律让给远端：
    /// 菜单项启用着就会先吃掉 ⌘W / ⌃Tab / ⌘T 等，在 RDP 窗口按 ⌘W 甚至会直接关窗断开连接。禁用后按键落回画面的 keyDown。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let appActions: Set<Selector> = [#selector(newTerminal), #selector(closeTab), #selector(nextTab),
                                         #selector(previousTab), #selector(toggleSidebar), #selector(increaseFont),
                                         #selector(decreaseFont), #selector(showSettings), #selector(selectTabNumber(_:))]
        guard let action = menuItem.action, appActions.contains(action), let key = NSApp.keyWindow else { return true }
        if key.windowController is RDPWindowController { return false }
        if key.firstResponder is RDPMouseView { return false }
        return true
    }

    /// key 窗口是否为主窗口（mainWindow 尚未登记时按「可成为主窗口、且不是 RDP 独立窗口」认定）。
    private func isMainWindow(_ w: NSWindow) -> Bool {
        if let mainWindow { return w === mainWindow }
        return w.canBecomeMain && !(w.windowController is RDPWindowController)
    }

    /// 标签类快捷键只作用于主窗口，且主窗口上有弹窗时不动下面的标签（RDP 独立窗口、关于窗口为 key 时同理）。
    private func withMainWindowModel(_ body: @MainActor (AppModel) -> Void) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            guard let key = NSApp.keyWindow, isMainWindow(key), !model.isModalPresented else { return }
            body(model)
        }
    }

    @objc private func newTerminal() {
        withMainWindowModel { $0.newTerminalShortcut() }
    }

    /// 主窗口：有弹窗时不动下层标签，否则关当前标签，没有标签时等同关窗口（隐藏到菜单栏 / 退出确认流程）。
    /// 其它窗口（RDP、关于）：关该窗口。
    @objc private func closeTab() {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            guard let key = NSApp.keyWindow else { return }
            guard isMainWindow(key) else { key.performClose(nil); return }
            if model.isModalPresented { return }
            if !model.closeActiveTabShortcut() { key.performClose(nil) }
        }
    }

    @objc private func nextTab() {
        withMainWindowModel { $0.selectAdjacentTab(1) }
    }

    @objc private func previousTab() {
        withMainWindowModel { $0.selectAdjacentTab(-1) }
    }

    @objc private func toggleSidebar() {
        withMainWindowModel { $0.toggleSidebar() }
    }

    @objc private func increaseFont() {
        MainActor.assumeIsolated { AppModel.shared.adjustTerminalFontSize(1) }
    }

    @objc private func decreaseFont() {
        MainActor.assumeIsolated { AppModel.shared.adjustTerminalFontSize(-1) }
    }

    @objc private func checkForUpdates() {
        MainActor.assumeIsolated { UpdateController.shared.checkForUpdates() }   // 菜单动作恒在主线程投递
    }

    @objc private func showAbout() {
        if aboutWindow == nil {
            let hosting = NSHostingView(rootView: AboutWindow())
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = String(localized: "关于 Termo")
            w.isReleasedWhenClosed = false
            w.contentView = hosting
            w.setContentSize(NSSize(width: 460, height: hosting.fittingSize.height))
            w.center()
            aboutWindow = w
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAppIcon() {
        let url = Bundle.app.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.app.url(forResource: "AppIcon", withExtension: "png")
        if let url, let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }

    // 关窗行为完全由 windowShouldClose 接管（隐藏到托盘或走退出流程），故不让系统在关窗后自动退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct ContentView: View {
    // 不订阅 AppModel：它被侧栏、活动栏等各自订阅，这里订阅会让整棵界面随任何数据变化重算。
    // 本视图只关心弹窗状态（DialogState），读写弹窗属性仍经 model 的同名转发。
    private let model = AppModel.shared
    @ObservedObject private var dialogs = AppModel.shared.dialogs
    // 侧栏宽度独立成一个对象,拖动它不会牵动 TabBar/Workspace 重算(见 LayoutModel)。
    private var layout: LayoutModel { model.layoutModel }
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            ActivityBar(model: model, layout: layout)
            Sidebar(model: model, tabs: model.tabsModel, layout: layout)
            // zIndex(1)：拖动时分隔条会画一条越过工作区的引导线,须盖在工作区之上。
            SidebarDividerSlot(model: model, layout: layout)
                .zIndex(1)
            VStack(spacing: 0) {
                TabBar(model: model, tabs: model.tabsModel)
                Workspace(model: model, tabs: model.tabsModel)
                    .padding([.leading, .top], 3)
            }
            .background(Pal.mantle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.base)
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .preferredColorScheme(theme.isDark ? .dark : .light)
        // 面板类弹窗（设置/新增主机/端口转发…）放在最底层，各种确认框都叠在它们之上。
        .modifier(AppPanels(model: model, dialogs: dialogs))
        // 注意：动画必须局限在各自 overlay 的 ZStack 内，不能加在视图链上——否则会泄漏到其它弹窗子树。
        .overlay {
            ZStack {
                if model.pendingCloseTabId != nil {
                    ConfirmDialog(
                        verbatimTitle: model.pendingCloseDialogTitle,
                        verbatimMessage: model.pendingCloseDialogMessage,
                        confirmTitle: "关闭",
                        destructive: true,
                        onConfirm: { model.confirmPendingClose() },
                        onCancel: { model.cancelPendingClose() }
                    )
                    .transition(.opacity)
                }
                if let ctx = model.pendingMultiClose {
                    ConfirmDialog(
                        title: "关闭 \(ctx.ids.count) 个标签？",
                        message: "其中有运行中的会话或未保存的修改，关闭将中断或丢弃。",
                        confirmTitle: "全部关闭",
                        destructive: true,
                        onConfirm: { model.confirmMultiClose() },
                        onCancel: { model.cancelMultiClose() }
                    )
                    .transition(.opacity)
                }
                if let ctx = model.pendingTabRename {
                    RenameDialog(
                        originalName: ctx.currentTitle, title: "重命名标签",
                        onConfirm: { model.renameTab(ctx.id, to: $0) },
                        onCancel: { model.pendingTabRename = nil }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.pendingCloseTabId)
            .animation(.easeOut(duration: 0.15), value: model.pendingMultiClose?.id)
            .animation(.easeOut(duration: 0.15), value: model.pendingTabRename?.id)
            // 无弹窗时整层不吃点击：避免 .transition 关闭后残留的透明命中层挡住下方内容
            //（SwiftUI overlay+transition+ignoresSafeArea 的已知缺陷，下同）。
            .allowsHitTesting(model.pendingCloseTabId != nil || model.pendingMultiClose != nil || model.pendingTabRename != nil)
        }
        // 连接相关弹窗（连接进度 / 指纹验证 / 每次询问密码 / 片段变量填值）统一抽到一个 ViewModifier，
        // 避免 body 的 overlay 链过长触发「编译器类型检查超时」（同 AppSheets 的拆分思路）。
        .modifier(ConnectionDialogs(model: model, dialogs: dialogs))
        .overlay { FileOpOverlays(model: model, dialogs: dialogs) }
        .overlay {
            // 下载不弹窗时的弧线飞入动画：满窗叠层、不吃点击；事件结束即移除（按 id 防被旧动画误清）。
            // 起点/终点都在 SwiftUI 全局坐标；这里减去叠层自身的全局原点换算到本地坐标，
            // 与窗口大小、位置、安全区无关，故各种尺寸下起止点都精确对齐。
            GeometryReader { proxy in
                if let fly = model.flyTransfer {
                    let o = proxy.frame(in: .global).origin
                    FlyToCornerView(
                        from: CGPoint(x: fly.from.x - o.x, y: fly.from.y - o.y),
                        to: CGPoint(x: model.backgroundButtonCenter.x - o.x,
                                    y: model.backgroundButtonCenter.y - o.y)
                    ) {
                        if model.flyTransfer?.id == fly.id { model.flyTransfer = nil }
                    }
                    .id(fly.id)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay {
            ZStack {
                if model.pendingQuitConfirm {
                    QuitConfirmDialog(
                        model: model,
                        forceMode: model.pendingQuitForce,
                        onCancel: { model.pendingQuitConfirm = false; model.pendingQuitForce = false },
                        onHideToTray: {
                            model.pendingQuitConfirm = false
                            model.pendingQuitForce = false
                            AppSettings.shared.closeToTray = true
                            // 仅隐藏可成为主窗口的内容窗口；放过托盘 NSStatusBarWindow（canBecomeMain==false），
                            // 否则 macOS 15 会丢托盘图标。详见 AppDelegate.hideToTray 的过滤说明。
                            for w in NSApp.windows where w.isVisible && w.canBecomeMain {
                                w.orderOut(nil)
                            }
                            NSApp.setActivationPolicy(.accessory)
                        },
                        onConfirm: {
                            model.pendingQuitConfirm = false
                            model.pendingQuitForce = false
                            AppDelegate.quitConfirmed = true
                            model.stopAllBackground()
                            ForwardProcessRegistry.shared.terminateAll()
                            NSApp.terminate(nil)
                        }
                    ).transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.pendingQuitConfirm)
            .allowsHitTesting(model.pendingQuitConfirm)
        }
        .overlay { alertOverlays }
        .onChange(of: dialogs.isModalPresented) { _, presented in
            // 弹窗出现：键盘从终端/编辑器收回（否则按键打进被遮住的终端）；全部关闭：焦点还给当前标签。
            if presented { model.resignTabFocus() } else { model.focusActiveTab() }
        }
        .onAppear { model.applyStartupIfNeeded() }
    }

    /// 操作失败 / 提示（原系统 alert），在最上层。
    @ViewBuilder
    private var alertOverlays: some View {
        ZStack {
            if let msg = model.keyOpError {
                ConfirmDialog(verbatimTitle: String(localized: "操作失败"), verbatimMessage: msg,
                              confirmTitle: "好", showCancel: false,
                              onConfirm: { model.keyOpError = nil }, onCancel: { model.keyOpError = nil })
                    .transition(.opacity)
            }
            if let msg = model.snippetNotice {
                ConfirmDialog(verbatimTitle: String(localized: "提示"), verbatimMessage: msg,
                              confirmTitle: "好", showCancel: false,
                              onConfirm: { model.snippetNotice = nil }, onCancel: { model.snippetNotice = nil })
                    .transition(.opacity)
            }
            if let key = dialogs.pendingKeyDelete {
                let users = model.hostsUsingKey(key)
                ConfirmDialog(
                    verbatimTitle: String(localized: "删除密钥「\(key.name)」？"),
                    verbatimMessage: users.isEmpty
                        ? String(localized: "私钥将从钥匙串和本机移除，不可恢复。")
                        : String(localized: "私钥将从钥匙串和本机移除，不可恢复。以下主机正在使用它，删除后将无法用密钥登录：\(users.joined(separator: "、"))"),
                    confirmTitle: "删除", destructive: true,
                    onConfirm: { model.confirmKeyDelete() },
                    onCancel: { model.pendingKeyDelete = nil }
                ).transition(.opacity)
            }
            if let snippet = dialogs.pendingSnippetDelete {
                ConfirmDialog(
                    verbatimTitle: String(localized: "删除片段「\(snippet.name)」？"),
                    verbatimMessage: String(localized: "删除后不可恢复。"),
                    confirmTitle: "删除", destructive: true,
                    onConfirm: { model.confirmSnippetDelete() },
                    onCancel: { model.pendingSnippetDelete = nil }
                ).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.keyOpError)
        .animation(.easeOut(duration: 0.15), value: model.snippetNotice)
        .animation(.easeOut(duration: 0.15), value: dialogs.pendingKeyDelete?.id)
        .animation(.easeOut(duration: 0.15), value: dialogs.pendingSnippetDelete?.id)
        .allowsHitTesting(model.keyOpError != nil || model.snippetNotice != nil
                          || dialogs.pendingKeyDelete != nil || dialogs.pendingSnippetDelete != nil)
    }
}

/// 文件栏右键操作的弹窗叠层 + 传输/解压对话框。单独成视图：它要读传输列表（AppModel），
/// 放在 ContentView 里会让 ContentView 为此订阅整个 AppModel。
private struct FileOpOverlays: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dialogs: DialogState

    var body: some View { fileOpOverlays }

    @ViewBuilder
    private var fileOpOverlays: some View {
        ZStack {
            if let ctx = model.pendingFileDelete {
                ConfirmDialog(
                    title: "删除「\(ctx.file.name)」？",
                    message: ctx.file.isDir ? "该目录及其全部内容将被永久删除，不可恢复。" : "该文件将被永久删除，不可恢复。",
                    confirmTitle: "删除", destructive: true,
                    busy: model.fileDeleteBusy,
                    onConfirm: { model.confirmFileDelete() },
                    onCancel: { model.cancelFileDelete() }
                ).transition(.opacity)
            }
            if let h = model.pendingHostDelete {
                ConfirmDialog(
                    title: "删除主机「\(h.name)」？",
                    message: "该主机的配置（含保存的密码、会话历史、端口转发规则）将被删除，不可恢复。",
                    confirmTitle: "删除", destructive: true,
                    onConfirm: { model.confirmHostDelete() },
                    onCancel: { model.cancelHostDelete() }
                ).transition(.opacity)
            }
            if let ctx = model.pendingBatchDelete {
                ConfirmDialog(
                    title: "删除 \(ctx.files.count) 个项目？",
                    message: "选中的项目（含其中的目录及内容）将被永久删除，不可恢复。",
                    confirmTitle: "删除", destructive: true,
                    busy: model.batchDeleteBusy,
                    onConfirm: { model.confirmBatchDelete() },
                    onCancel: { model.cancelBatchDelete() }
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
            if let ctx = model.pendingFileCreate {
                RenameDialog(
                    originalName: "", title: ctx.isDir ? "新建文件夹" : "新建文件",
                    onConfirm: { model.confirmFileCreate(name: $0) },
                    onCancel: { model.pendingFileCreate = nil }
                ).transition(.opacity)
            }
            if let info = model.pendingFileInfo {
                ConfirmDialog(
                    verbatimTitle: info.title, verbatimMessage: info.message,
                    confirmTitle: "好的", showCancel: false,
                    onConfirm: { model.pendingFileInfo = nil },
                    onCancel: { model.pendingFileInfo = nil }
                ).transition(.opacity)
            }
            if let id = model.focusedTransferId, let task = model.transfers.first(where: { $0.id == id }) {
                UploadDialog(task: task,
                             onHide: { model.focusedTransferId = nil },
                             onClose: { model.removeTransfer(id) })
                    .transition(.opacity)
            }
            if let task = model.extractTask, model.showExtractDialog {
                ExtractDialog(task: task,
                              onHide: { model.showExtractDialog = false },
                              onClose: { model.extractTask = nil; model.showExtractDialog = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.focusedTransferId)
        .animation(.easeOut(duration: 0.18), value: model.extractTask?.id)
        .animation(.easeOut(duration: 0.18), value: model.showExtractDialog)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileDelete?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingBatchDelete?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingHostDelete?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileRename?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileChmod?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileCreate?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileRefresh?.id)
        .animation(.easeOut(duration: 0.15), value: model.pendingFileInfo?.id)
        // 无任何文件弹窗时整层不吃点击，杜绝 .transition 关闭后残留命中层卡住界面。
        .allowsHitTesting(anyFileOverlayActive)
    }

    /// 文件操作叠层里是否有弹窗正在展示（含展开的上传/下载对话框）。
    private var anyFileOverlayActive: Bool {
        model.pendingFileDelete != nil || model.pendingBatchDelete != nil || model.pendingHostDelete != nil || model.pendingFileRefresh != nil ||
        model.pendingFileRename != nil || model.pendingFileChmod != nil ||
        model.pendingFileCreate != nil || model.pendingFileInfo != nil ||
        model.focusedTransferId != nil ||
        (model.extractTask != nil && model.showExtractDialog)
    }
}

/// 侧栏分隔条：文件栏可拖得更宽（容纳深层目录树），其它区上限 320，因此要读当前分区。
/// 单独成视图，分区变化只重算这一小块。
private struct SidebarDividerSlot: View {
    @ObservedObject var model: AppModel
    let layout: LayoutModel

    var body: some View {
        SidebarDivider(layout: layout, maxWidth: model.section == .files ? 600 : 320)
            .onChange(of: model.section) { _, sec in
                // 离开文件栏时，若超过常规上限则收回（额外宽度是文件栏的特权）。
                // 瞬间收回(不加动画):宽度动画会逐帧重排工作区,造成卡顿。
                if sec != .files, layout.sidebarWidth > 320 { layout.sidebarWidth = 320 }
            }
    }
}

/// 把全部 sheet 与 alert 收进一个 ViewModifier：避免 ContentView.body 单表达式过长，
/// 触发「编译器无法在合理时间内类型检查」。
/// 连接相关弹窗叠层（从 ContentView.body 拆出，缩短 overlay 链以避免类型检查超时）。
/// 应用顺序即叠放顺序：连接进度 → 指纹验证 → 每次询问密码 → 片段变量填值（后者在最上）。
private struct ConnectionDialogs: ViewModifier {
    let model: AppModel
    @ObservedObject var dialogs: DialogState

    func body(content: Content) -> some View {
        content
            // RDP 连接弹窗：覆盖当前概览/列表，连接成功才开标签；含连接进度与证书信任框。
            .overlay {
                ZStack {
                    if let s = model.connectingRDP {
                        RDPConnectingDialog(session: s,
                                            onConnected: { model.finishRDPConnecting() },
                                            onCancel: { model.cancelRDPConnecting() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: model.connectingRDP != nil)
                .allowsHitTesting(model.connectingRDP != nil)
            }
            // RDP 连接成功后的打开方式选择（内嵌 / 新窗口），仅在设置为「每次询问」时出现。
            .overlay {
                ZStack {
                    if let s = model.pendingRDPOpen {
                        RDPOpenDialog(hostName: s.host.name,
                                      onChoose: { model.resolveRDPOpen(s, window: $0, remember: $1) },
                                      onCancel: { model.cancelRDPOpen() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingRDPOpen != nil)
                .allowsHitTesting(model.pendingRDPOpen != nil)
            }
            .overlay {
                ZStack {
                    if let h = model.connectingHost {
                        ConnectingDialog(host: h,
                                         successHint: model.connectingActionHint,
                                         verify: { await model.verifyHostKey(h) },
                                         onConnected: { model.finishConnecting() },
                                         onCancel: { model.cancelConnecting() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: model.connectingHost?.id)
                .allowsHitTesting(model.connectingHost != nil)
            }
            // 指纹验证弹窗叠在连接弹窗之上（未知主机首次连接时需用户核对）
            .overlay {
                ZStack {
                    if let pending = model.pendingHostKey {
                        HostKeyDialog(pending: pending).transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingHostKey?.id)
                .allowsHitTesting(model.pendingHostKey != nil)
            }
            // 「每次询问」主机连接前的一次性密码弹窗（在连接弹窗之前出现）
            .overlay {
                ZStack {
                    if let h = model.pendingAskAuth {
                        AskPasswordDialog(host: h,
                                          onConfirm: { model.submitAskAuth($0) },
                                          onCancel: { model.cancelAskAuth() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingAskAuth?.id)
                .allowsHitTesting(model.pendingAskAuth != nil)
            }
            // 片段「插入/运行」选择弹窗（默认动作为「每次询问」时）
            .overlay {
                ZStack {
                    if let s = model.pendingSnippetAction {
                        SnippetActionDialog(snippet: s,
                                            onChoose: { model.resolveSnippetAction(s, run: $0, remember: $1) },
                                            onCancel: { model.cancelSnippetAction() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingSnippetAction?.id)
                .allowsHitTesting(model.pendingSnippetAction != nil)
            }
            // 含 {{变量}} 的片段运行/插入前的填值弹窗
            .overlay {
                ZStack {
                    if let req = model.pendingSnippetRun {
                        SnippetRunDialog(request: req,
                                         onConfirm: { model.submitSnippetRun($0) },
                                         onCancel: { model.cancelSnippetRun() })
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.pendingSnippetRun?.id)
                .allowsHitTesting(model.pendingSnippetRun != nil)
            }
    }
}

/// 面板类弹窗：原系统 sheet 改为窗口内叠层（点空白处关闭，与其它自定义弹窗一致）。
/// 拆成两段 ViewModifier：单个修饰链过长会触发「编译器无法在合理时间内类型检查」。
private struct AppPanels: ViewModifier {
    let model: AppModel
    @ObservedObject var dialogs: DialogState

    func body(content: Content) -> some View {
        content
            .modalOverlay(isPresented: model.showSettings, onDismiss: { model.showSettings = false }) {
                SettingsView(model: model)
            }
            .modalOverlay(isPresented: model.showAddHost, onDismiss: { model.showAddHost = false }) {
                AddHostView(model: model)
            }
            .modalOverlay(isPresented: model.editingHost != nil, onDismiss: { model.editingHost = nil }) {
                if let host = model.editingHost { AddHostView(model: model, editing: host).id(host.id) }
            }
            .modalOverlay(isPresented: model.showAddRDPHost, onDismiss: { model.showAddRDPHost = false }) {
                AddRDPHostView(model: model)
            }
            .modalOverlay(isPresented: model.editingRDPHost != nil, onDismiss: { model.editingRDPHost = nil }) {
                if let host = model.editingRDPHost { AddRDPHostView(model: model, editing: host).id(host.id) }
            }
            .modifier(AppPanelsMore(model: model, dialogs: dialogs))
    }
}

private struct AppPanelsMore: ViewModifier {
    let model: AppModel
    @ObservedObject var dialogs: DialogState

    func body(content: Content) -> some View {
        content
            .modalOverlay(isPresented: model.forwardPanelHost != nil, onDismiss: { model.forwardPanelHost = nil }) {
                if let host = model.forwardPanelHost { PortForwardView(model: model, host: host).id(host.id) }
            }
            .modalOverlay(isPresented: model.showGenerateKey, onDismiss: { model.showGenerateKey = false }) {
                GenerateKeyView(model: model)
            }
            .modalOverlay(isPresented: model.detailKey != nil, onDismiss: { model.detailKey = nil }) {
                if let key = model.detailKey { KeyDetailView(model: model, key: key).id(key.id) }
            }
            .modalOverlay(isPresented: model.showCreateSnippet, onDismiss: { model.showCreateSnippet = false }) {
                SnippetEditView(model: model)
            }
            .modalOverlay(isPresented: model.editingSnippet != nil, onDismiss: { model.editingSnippet = nil }) {
                if let snip = model.editingSnippet { SnippetEditView(model: model, editing: snip).id(snip.id) }
            }
            // 由面板内再打开的二级弹窗，叠在面板之上。
            .modalOverlay(isPresented: model.testConnectionDraft != nil, onDismiss: { model.testConnectionDraft = nil }) {
                if let draft = model.testConnectionDraft {
                    TestConnectionView(draft: draft, verify: { await model.verifyHostKey(conn: $0) })
                }
            }
            .modalOverlay(isPresented: model.showPrivacyPolicy, onDismiss: { model.showPrivacyPolicy = false }) {
                PrivacyPolicyView()
            }
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
                // 窗口底色设为品牌 base：首帧即深/浅品牌底，避免默认窗口底色造成冷启动闪白。
                w.backgroundColor = ThemeManager.shared.windowBackground
                w.isOpaque = true
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.styleMask.insert(.fullSizeContentView)
                // 冷启动不自动聚焦搜索框：否则 macOS 会给聚焦的文本框弹自动填充/输入法候选浮层，
                // 启动瞬间闪现一帧白色圆角卡片。清掉初始第一响应者，用户点击搜索框仍可正常聚焦。
                w.initialFirstResponder = nil
                w.makeFirstResponder(nil)
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
