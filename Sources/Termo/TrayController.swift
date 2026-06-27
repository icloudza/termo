import AppKit
import Combine

/// 菜单栏（托盘）控制器：常驻一个状态栏图标，承载「显示窗口 / 后台任务概览 / 退出」。
/// 让端口转发等常驻后台任务在主窗口隐藏后仍可被看到与管理（隐藏到托盘时见 AppDelegate）。
@MainActor
final class TrayController: NSObject, NSMenuDelegate {
    /// 供退出弹窗等处直接重建状态栏图标（不绕 AppDelegate 引用）。AppDelegate 持有强引用，此处弱引用即可。
    static weak var shared: TrayController?

    private var statusItem: NSStatusItem?
    private let onShow: () -> Void
    private let onQuit: () -> Void
    private var bgCancellable: AnyCancellable?
    private var lastRunning = false   // 当前图标是否为「有后台任务」态（`_` 蓝绿呼吸），用于去重避免无谓重绘
    private var animTimer: Timer?
    private var animPhase: Double = 0

    // `_` 的两端颜色：品牌蓝 ↔ 运行绿，有任务时在两者间正弦平滑往返。
    private static let barBlue  = NSColor(srgbRed: 0.25, green: 0.62, blue: 1.0,  alpha: 1)
    private static let barGreen = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)

    init(onShow: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onShow = onShow
        self.onQuit = onQuit
        super.init()
        install()
        Self.shared = self
        // 后台任务起止时（AppModel 在这些时刻 publish）刷新 `_` 的颜色；进度逐帧变化不经 AppModel，无重绘风暴。
        bgCancellable = AppModel.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refreshRunningIfNeeded() }
        }
    }

    /// 切到 .accessory 后确保图标仍显示。**不重建**——重建会闪烁，且新实例会插回默认位置，
    /// 丢掉用户在菜单栏里拖动调整过的位置。只对已存在的图标重新点亮可见性即可；从未创建过才创建。
    /// 策略切换是异步的，故延后再点亮一次，兜住部分 macOS（含 15）切 .accessory 后把图标隐去的时序。
    func rebuild() {
        guard statusItem != nil else { install(); return }
        reassertVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.reassertVisible() }
    }

    /// 重新点亮已存在的状态栏图标（不新建，保留其位置）；顺带按当前后台状态刷新图标（含小圆点）。
    private func reassertVisible() {
        statusItem?.isVisible = true
        updateImage()
    }

    /// 首次创建状态栏图标（仅一次，常驻整个 App 生命周期）。已存在则只确保可见，绝不移除重建。
    private func install() {
        if statusItem != nil { reassertVisible(); return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "Termo"
        item.isVisible = true
        let menu = NSMenu()
        menu.delegate = self   // 每次打开时按当前后台任务刷新
        item.menu = menu
        statusItem = item
        updateImage()
    }

    /// 后台任务起止时刷新 `_` 的颜色（仅在有/无切换时重绘）。
    private func refreshRunningIfNeeded() {
        if (AppModel.shared.activeBackgroundCount > 0) != lastRunning { updateImage() }
    }

    /// 按当前后台状态设置图标：有进行中任务 → `_` 在蓝绿间正弦平滑往返；否则静态品牌蓝。
    private func updateImage() {
        let running = AppModel.shared.activeBackgroundCount > 0
        lastRunning = running
        if running {
            startAnimating()
        } else {
            stopAnimating()
            statusItem?.button?.image = Self.logoImage(barColor: Self.barBlue)
        }
    }

    /// 启动 `_` 的蓝绿呼吸（约 20fps，周期 ~1.8s）；仅有任务时运行，幂等。
    private func startAnimating() {
        guard animTimer == nil else { return }
        animTick()   // 立即出一帧，避免首帧延迟
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.animTick() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common：菜单/拖动等模式下仍走动画
        animTimer = t
    }

    private func stopAnimating() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func animTick() {
        animPhase += 0.18                          // 步进：周期约 2π/0.18×0.05s ≈ 1.75s
        let f = CGFloat((sin(animPhase) + 1) / 2)  // 0…1 平滑往返
        statusItem?.button?.image = Self.logoImage(barColor: Self.lerp(Self.barBlue, Self.barGreen, f))
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
