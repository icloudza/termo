import AppKit
import Combine

/// 菜单栏（托盘）控制器：常驻一个状态栏图标，承载「显示窗口 / 后台任务概览 / 退出」。
/// 让端口转发等常驻后台任务在主窗口隐藏后仍可被看到与管理（隐藏到托盘时见 AppDelegate）。
@MainActor
final class TrayController: NSObject, NSMenuDelegate {
    /// 单例弱引用，供需要时在 AppDelegate 之外访问托盘控制器。AppDelegate 持有强引用，此处弱引用即可。
    static weak var shared: TrayController?

    private var statusItem: NSStatusItem?
    private let onShow: () -> Void
    private let onQuit: () -> Void
    private var bgCancellable: AnyCancellable?
    /// 灯的三态：空闲（静态蓝）/ 运行中（蓝绿呼吸）/ 有失败（红色呼吸）。红 > 运行 > 空闲。
    private enum LightMode { case idle, running, failure }
    private var lastMode: LightMode = .idle   // 去重避免无谓重绘
    private var animTimer: Timer?
    private var animPhase: Double = 0

    // `_` 的呼吸两端色（两端都取高明度，靠色相往返出动感，避免某端发暗发脏）：
    // 运行态 品牌蓝↔运行绿；失败态 亮红↔暖橙红（脉冲告警感，不发黑）。
    private static let barBlue   = NSColor(srgbRed: 0.25, green: 0.62, blue: 1.00, alpha: 1)
    private static let barGreen  = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    private static let barRed    = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.24, alpha: 1)
    private static let barRedAlt = NSColor(srgbRed: 1.00, green: 0.55, blue: 0.32, alpha: 1)

    init(onShow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onShow = onShow
        self.onQuit = onQuit
        super.init()
        install()
        Self.shared = self
        // 后台任务起止/失败时（AppModel 在这些时刻 publish）刷新 `_` 的颜色；进度逐帧变化不经 AppModel，无重绘风暴。
        bgCancellable = AppModel.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshIfNeeded() }
        }
    }

    /// 创建状态栏图标（仅一次，常驻整个 App 生命周期，绝不移除/重建/隐藏）。
    /// 关键设计：状态项与激活策略（.regular↔.accessory）及窗口生命周期完全解耦——隐藏到托盘时
    /// 只 orderOut 内容窗口、放过 NSStatusBarWindow（见 AppDelegate.hideToTray），故图标始终在线；
    /// 从不调用 removeStatusItem（它会清掉 autosaveName 的位置槽 ⟹ 位置漂移），故用户拖动的位置天然保留。
    /// autosaveName 仅用于跨重启持久化位置。
    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "TermoBackgroundStatusItem"   // 持久化位置：重建/重启后还原到用户拖动的位置
        item.button?.toolTip = "Termo"
        item.isVisible = true
        let menu = NSMenu()
        menu.delegate = self   // 每次打开时按当前后台任务刷新
        item.menu = menu
        statusItem = item
        updateImage()
    }

    /// 当前应处的灯态：失败优先（红） > 运行中（蓝绿） > 空闲（静态蓝）。
    private func currentMode() -> LightMode {
        if AppModel.shared.hasBackgroundFailure { return .failure }
        if AppModel.shared.activeBackgroundCount > 0 { return .running }
        return .idle
    }

    /// 后台状态变化时刷新 `_`（仅在灯态切换时重绘）。
    private func refreshIfNeeded() {
        if currentMode() != lastMode { updateImage() }
    }

    /// 按当前灯态设置图标：失败/运行 → 呼吸动画；空闲 → 静态品牌蓝。
    private func updateImage() {
        let mode = currentMode()
        lastMode = mode
        switch mode {
        case .idle:
            stopAnimating()
            statusItem?.button?.image = Self.logoImage(barColor: Self.barBlue)
        case .running, .failure:
            startAnimating()
        }
    }

    /// 启动 `_` 的呼吸（约 20fps，周期 ~1.8s）；仅有任务/失败时运行，幂等。
    private func startAnimating() {
        guard animTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.animTick() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common：菜单/拖动等模式下仍走动画
        animTimer = t
        animTick()   // 立即出一帧，避免首帧延迟（须在 animTimer 赋值后，否则被下方 guard 拦掉）
    }

    private func stopAnimating() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func animTick() {
        // 防卡色根因①（竞态）：stopAnimating 只 invalidate timer，但其回调里已 enqueue 的 Task 仍会执行一次；
        // 不拦的话它会在 updateImage 把图标设回静态蓝之后再覆盖成插值帧 → 停在中间色。invalidate 后 animTimer=nil，据此早退。
        guard animTimer != nil else { return }
        // 防卡色根因②（漏发布）：任务结束/失败清除偶尔没经 AppModel publish（子对象 phase 翻转不冒泡），
        // 托盘收不到刷新通知而一直转。动画期间每帧自校验真相源：转空闲即停并复位静态蓝；失败↔运行切换则换色。
        let mode = currentMode()
        if mode == .idle { updateImage(); return }
        if mode != lastMode { lastMode = mode }    // 运行↔失败 在动画中平滑切色，同步去重态
        animPhase += 0.18                          // 步进：周期约 2π/0.18×0.05s ≈ 1.75s
        let f = CGFloat((sin(animPhase) + 1) / 2)  // 0…1 平滑往返
        let color = mode == .failure
            ? Self.lerp(Self.barRed, Self.barRedAlt, f)    // 失败：亮红↔暖橙红脉冲告警
            : Self.lerp(Self.barBlue, Self.barGreen, f)    // 运行：品牌蓝↔运行绿
        statusItem?.button?.image = Self.logoImage(barColor: color)
    }

    /// 在 sRGB 分量间线性插值两色。
    private static func lerp(_ a: NSColor, _ b: NSColor, _ f: CGFloat) -> NSColor {
        NSColor(srgbRed: a.redComponent   + (b.redComponent   - a.redComponent)   * f,
                green:   a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                blue:    a.blueComponent  + (b.blueComponent  - a.blueComponent)  * f,
                alpha: 1)
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

    /// 菜单栏图标：终端提示符 `>_`。`>` 跟随明暗菜单栏的标签色；`_` 用 `barColor`（平时品牌蓝，
    /// 有后台任务时由上层在蓝绿间平滑过渡）。因含彩色不能用模板渲染（会被强制单色）；
    /// `>` 用 labelColor 在绘制时按目标外观解析，仍随明暗自适应。
    static func logoImage(barColor: NSColor) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let chevron = NSBezierPath()
            chevron.lineWidth = 2.3
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 4.3, y: 13.6))
            chevron.line(to: NSPoint(x: 9.4, y: 9))
            chevron.line(to: NSPoint(x: 4.3, y: 4.4))
            chevron.stroke()
            // `_`：先用更宽的白色描一遍垫底，再描蓝色——蓝线四周露出约 0.3px 细白边，
            // 避免蓝色壁纸（暗色菜单栏透出）把蓝色 `_` 同化，同时足够细不影响观感。
            let bar = NSBezierPath()
            bar.lineCapStyle = .round
            bar.move(to: NSPoint(x: 12.3, y: 4.4))   // 与 > 拉开一点间距
            bar.line(to: NSPoint(x: 16.0, y: 4.4))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            bar.lineWidth = 2.9
            bar.stroke()
            barColor.setStroke()
            bar.lineWidth = 2.3
            bar.stroke()
            return true
        }
        img.isTemplate = false   // 含蓝色 `_`，关闭模板渲染（否则会被系统强制单色）
        return img
    }
}
