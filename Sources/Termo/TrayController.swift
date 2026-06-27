import AppKit

/// 菜单栏（托盘）控制器：常驻一个状态栏图标，承载「显示窗口 / 后台任务概览 / 退出」。
/// 让端口转发等常驻后台任务在主窗口隐藏后仍可被看到与管理（隐藏到托盘时见 AppDelegate）。
@MainActor
final class TrayController: NSObject, NSMenuDelegate {
    /// 供退出弹窗等处直接重建状态栏图标（不绕 AppDelegate 引用）。AppDelegate 持有强引用，此处弱引用即可。
    static weak var shared: TrayController?

    private var statusItem: NSStatusItem?
    private let onShow: () -> Void
    private let onQuit: () -> Void

    init(onShow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onShow = onShow
        self.onQuit = onQuit
        super.init()
        install()
        Self.shared = self
    }

    /// 创建（或重建）状态栏图标。运行时把激活策略从 .regular 切到 .accessory 时，
    /// 已存在的 NSStatusItem 在部分 macOS 版本（含 15）会被系统丢弃，切换后调用本方法恢复显示。
    func rebuild() { install() }

    private func install() {
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.logoImage()
        item.button?.toolTip = "Termo"
        let menu = NSMenu()
        menu.delegate = self   // 每次打开时按当前后台任务刷新
        item.menu = menu
        statusItem = item
    }

    // 菜单打开前重建：显示当前进行中的后台任务清单 + 操作项。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let show = NSMenuItem(title: "显示 Termo", action: #selector(showTapped), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())

        let tasks = AppModel.shared.runningBackgroundSummaries
        let header = NSMenuItem(title: tasks.isEmpty ? "无后台任务" : "后台任务（\(tasks.count)）",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        // 托盘菜单只作概览，至多列 6 条；更多任务引导回应用内的后台中控查看，避免菜单过高。
        let maxRows = 6
        for line in tasks.prefix(maxRows) {
            let it = NSMenuItem(title: "  " + line, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        if tasks.count > maxRows {
            let more = NSMenuItem(title: "  还有 \(tasks.count - maxRows) 项，打开应用查看",
                                  action: #selector(showTapped), keyEquivalent: "")
            more.target = self
            menu.addItem(more)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Termo", action: #selector(quitTapped), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func showTapped() { onShow() }
    @objc private func quitTapped() { onQuit() }

    /// 菜单栏图标：终端提示符 `>_`。`>` 用跟随明暗菜单栏的标签色，`_` 用品牌蓝以体现 logo 特色。
    /// 因含彩色不能用模板渲染（模板会被强制单色）；`>` 用 labelColor 在绘制时按目标外观解析，仍随明暗自适应。
    static func logoImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let blue = NSColor(srgbRed: 0.25, green: 0.62, blue: 1.0, alpha: 1)   // 品牌蓝的 `_`
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let chevron = NSBezierPath()
            chevron.lineWidth = 2.1
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 5, y: 13))
            chevron.line(to: NSPoint(x: 9.5, y: 9))
            chevron.line(to: NSPoint(x: 5, y: 5))
            chevron.stroke()
            // `_`：先用更宽的白色描一遍垫底，再描蓝色——蓝线四周露出约 0.6px 细白边，
            // 避免蓝色壁纸（暗色菜单栏透出）把蓝色 `_` 同化，同时足够细不影响观感。
            let bar = NSBezierPath()
            bar.lineCapStyle = .round
            bar.move(to: NSPoint(x: 12, y: 5))   // 与 > 拉开一点间距
            bar.line(to: NSPoint(x: 15.5, y: 5))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            bar.lineWidth = 2.7
            bar.stroke()
            blue.setStroke()
            bar.lineWidth = 2.1
            bar.stroke()
            return true
        }
        img.isTemplate = false   // 含蓝色 `_`，关闭模板渲染（否则会被系统强制单色）
        return img
    }
}
