import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages
import CodeEditTextView   // 改动竖条要用 layoutManager.textLineForIndex / textView.textInsets

/// 代码编辑器视图：包一层 CodeEditSourceEditor 的 SourceEditor（原生 TextKit 内核）。
/// 高亮 / 补全 UI / 查找替换(⌘F) / 缩略图 / 自动缩进 / 括号配对 全由该成熟库提供。
///
/// 接入对齐官方 Example：传配置 + `.frame(maxWidth/maxHeight: .infinity)` 占满。
/// 不换行时库会把文本视图撑到 `max(最长行, 视口)` 宽并开横滚（依赖 vendored 修复的 CodeEditTextView，
/// 上游 0.12.1 的 inout 遮蔽 bug 会让行宽算不出来导致没有横滚——见 LocalPackages/CodeEditTextView）。
/// 横滚条常驻 + 缩略图隐藏拦点击/显示盖正文，由 `EditorFixer` 在视图层级上微调修正。
struct RemoteCodeEditor: View {
    @Binding var text: String        // EditorState.text：远程拉回的内容，双向回写
    let editable: Bool               // .text → true；.readonlyText → false
    let fileName: String             // 用于按扩展名识别语言
    let colors: ThemeColors
    let isDark: Bool
    let font: NSFont
    let showMinimap: Bool
    let savedVersion: Int            // 基准版本号：变化时协调器从 TextView 实时快照新基准并对账
    var onEditorReady: ((NSView) -> Void)? = nil   // 文本视图就绪回调（keep-alive 聚焦登记用）

    @State private var editorState = SourceEditorState()
    @State private var changeBars = ChangeBarCoordinator()
    @State private var undoBreaker = TypingUndoBreaker()   // 快速打字撤销细粒度（停手即分段）

    private var language: CodeLanguage {
        // detectLanguageFrom 只读路径扩展名/文件名，不访问磁盘；远程文件用 fileURLWithPath 构造即可
        CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: fileName))
    }

    var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: EditorTheme.termo(colors: colors, isDark: isDark),
                    font: font,
                    wrapLines: false,                 // 代码不折行 → 长行横向滚动
                    tabWidth: 4
                ),
                behavior: .init(
                    isEditable: editable,
                    isSelectable: true,
                    indentOption: .spaces(count: 4)   // 自动缩进单位
                ),
                peripherals: .init(
                    showGutter: true,                 // 行号
                    showMinimap: showMinimap,         // 隐藏/避让交给库原生处理
                    showFoldingRibbon: false           // 关掉那条杂乱的常驻折叠竖条（Xcode 也不常驻显示）
                )
            ),
            state: $editorState,
            coordinators: [changeBars, undoBreaker]   // 改动竖条 + 撤销空闲打断
        )
        // 切换缩略图显隐时重建编辑器：隐藏时 EditorFixer 把 MinimapView removeFromSuperview 了，
        // 而库只在创建时建一次缩略图、不会重建 → 不重建的话再次显示就没了。重建让库重新建出缩略图。
        .id(showMinimap)
        // 占满可用宽高（对齐官方 Example），保证文本容器拿到确定的视口尺寸。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 视图层级微调（不改库逻辑）：① 横滚条常驻；② 缩略图隐藏移除/显示避让。
        .background(EditorFixer(showMinimap: showMinimap))
        .onAppear {
            if let cb = onEditorReady { undoBreaker.registerReady(cb) }
        }
        // 基准变化（加载/保存）→ 协调器从当前 TextView 文本快照新基准并重算
        .onChange(of: savedVersion) { _ in changeBars.markBaselineFromCurrent() }
    }
}

/// 修正 CodeEditSourceEditor 在我们嵌入下的两个问题（只动视图层级，不改库逻辑）。
/// 用一个零尺寸的背景 NSView 作锚点：它随 SwiftUI 在 `showMinimap` 变化时收到 `updateNSView`，
/// 用 `async` 延后到当帧布局（含库的 reloadUI/styleScrollView）跑完之后再施加，避免被库重置覆盖。
///
/// ① 横滚条常驻：库的 `styleScrollView` 写死 `scrollerStyle = .overlay`（只在滚动瞬间浮现）。
///    改成 `.legacy` + 不自动隐藏 → 一条常驻、可拖动的横向滚动条。
/// ② 缩略图：
///    - 隐藏时：仅靠库的 `isHidden` 在我们嵌入下仍会拦截缩略图那条区域的点击 → 直接 `removeFromSuperview`。
///    - 显示时：库初次算文本 inset 时缩略图宽常为 0、正文会钻到缩略图底下 → 等它有了宽度后补发
///      `contentView` 帧变化通知，触发库 `updateTextInsets()` 重算，让正文尽量以缩略图左缘为界。
private struct EditorFixer: NSViewRepresentable {
    let showMinimap: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        Self.schedule(from: nsView, show: showMinimap, attempt: 0)
    }

    /// 滚动视图/缩略图可能在本视图之后才建好/才有宽度，带重试直到处理成功（最多约 2.1s）。
    private static func schedule(from nsView: NSView, show: Bool, attempt: Int) {
        DispatchQueue.main.async {
            let done = editorRoot(from: nsView).map { apply(in: $0, show: show) } ?? false
            if !done && attempt < 14 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    schedule(from: nsView, show: show, attempt: attempt + 1)
                }
            }
        }
    }

    @discardableResult
    private static func apply(in root: NSView, show: Bool) -> Bool {
        guard let scroll = findEditorScrollView(in: root) else { return false }
        // ① 常驻横向滚动条（每次都重设，抵消库 reloadUI→styleScrollView 的 .overlay 重置）
        if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
        if scroll.autohidesScrollers { scroll.autohidesScrollers = false }
        // ② 缩略图
        if show {
            guard let minimap = findMinimap(in: root), minimap.frame.width > 1 else { return false }
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: scroll.contentView)
            return true
        } else {
            return removeMinimap(in: root)
        }
    }

    /// 从本视图向上找到第一个包含「编辑器滚动视图」的祖先（当前编辑器容器），避开 .id 重建残留。
    private static func editorRoot(from nsView: NSView) -> NSView? {
        var v: NSView? = nsView.superview
        while let cur = v {
            if findEditorScrollView(in: cur) != nil { return cur }
            v = cur.superview
        }
        return nsView.window?.contentView
    }

    private static func removeMinimap(in view: NSView) -> Bool {
        var done = false
        for sub in view.subviews {
            if String(describing: type(of: sub)) == "MinimapView" {
                sub.removeFromSuperview()
                done = true
            } else if removeMinimap(in: sub) {
                done = true
            }
        }
        return done
    }

    private static func findMinimap(in view: NSView) -> NSView? {
        if String(describing: type(of: view)) == "MinimapView" { return view }
        for sub in view.subviews {
            if let m = findMinimap(in: sub) { return m }
        }
        return nil
    }

    private static func findEditorScrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, let doc = s.documentView,
           String(describing: type(of: doc)).contains("TextView") {
            return s
        }
        for sub in view.subviews {
            if let s = findEditorScrollView(in: sub) { return s }
        }
        return nil
    }
}

/// 快速连续打字撤销细粒度：CEUndoManager 默认把一串相邻同向输入并成一个撤销组（一次 ⌘Z 删一大片，
/// 用户感觉「丢了撤销历史」）。这里在停止输入约 0.35s 后调 `breakTypingGroup()` 打断分组，
/// 让下一次输入起新组 —— 仿 Xcode/Ghostty 的细粒度撤销。仅作用于普通打字，不干扰库的缩进/注释等原子分组。
final class TypingUndoBreaker: TextViewCoordinator {
    private weak var controller: TextViewController?
    private var work: DispatchWorkItem?
    /// keep-alive 聚焦用：编辑器文本视图就绪时回调（上层据此把它登记到 EditorState.focusView）。
    private var onTextViewReady: ((NSView) -> Void)?

    func prepareCoordinator(controller: TextViewController) { self.controller = controller }

    func controllerDidAppear(controller: TextViewController) {
        self.controller = controller
        if let tv = controller.textView { onTextViewReady?(tv) }
    }

    /// SwiftUI 侧设置回调；若 controller 已就绪立即注册一次（兼顾 onAppear 与 controllerDidAppear 的时序）。
    func registerReady(_ cb: @escaping (NSView) -> Void) {
        onTextViewReady = cb
        if let tv = controller?.textView { cb(tv) }
    }

    func textViewDidChangeText(controller: TextViewController) {
        self.controller = controller
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.controller?.textView?._undoManager?.breakTypingGroup()
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    func destroy() { work?.cancel() }
}

/// 行号栏「已改行」竖条（相对上次保存，由 EditorState 逐行 diff 得出）。
/// 用官方 `TextViewCoordinator` 拿到 controller，把一块与 gutter 同样定位的浮层叠在 gutter 之上，
/// 在每条已改行左缘画一条主题色竖条。不改库逻辑、不拦截点击。
/// 变更竖条协调器——**位置锚定式（sticky）**，对齐 VSCode 脏 diff / CodeMirror RangeSet.map 的成熟做法。
/// 标记以「字符偏移」锚定在**当前文本坐标系**：每次编辑由 NSTextStorageDelegate **同步**把锚点随文本平移，
/// 因此**永不因异步滞后而错位**；后台 hunk-diff 仅做权威对账（算完用代际号核对文本未变才采纳）。
/// baseline（上次保存内容）直接从 TextView 快照，绕开 SwiftUI 绑定回灌的滞后。
final class ChangeBarCoordinator: NSObject, TextViewCoordinator, NSTextStorageDelegate {
    private weak var controller: TextViewController?
    private var barView: ChangeBarView?
    private var observers: [NSObjectProtocol] = []

    private var baselineLines: [String] = [""]    // 基准按 "\n" 切（与偏移同坐标，不归一 CRLF）
    private var dirtyOffsets: Set<Int> = []        // 各「已改行」行首的 UTF-16 偏移（当前文本坐标）

    private var recomputeWork: DispatchWorkItem?
    private var recomputeToken = 0
    private var editGeneration = 0                  // 每次编辑 +1：对账回主线程时据此丢弃过期结果
    private var baselineEstablished = false         // 防缩略图开关重建时把已改文本误当新基准
    private let diffQueue = DispatchQueue(label: "termo.changebar.diff", qos: .userInitiated)

    func prepareCoordinator(controller: TextViewController) { self.controller = controller }

    func controllerDidAppear(controller: TextViewController) {
        self.controller = controller
        install()                                  // 此时 scrollView/textView 已就绪，gutter 已先加 → 叠其上
        controller.textView?.addStorageDelegate(self)
        // 仅首次自动以当前内容为基准（空）；重建（缩略图开关）时跳过，保住既有竖条。
        // 真正的基准更新（保存/加载）始终经 savedVersion → markBaselineFromCurrent 触发。
        if !baselineEstablished { markBaselineFromCurrent() }
    }

    /// 基准变化（加载/保存后由 SwiftUI 经 savedVersion 触发）：以当前 TextView 文本为新基准并立即对账。
    func markBaselineFromCurrent() {
        guard let s = controller?.textView?.string else { return }
        baselineEstablished = true
        baselineLines = Self.splitLines(s)
        dirtyOffsets = []
        pushToView()
        recomputeNow()
    }

    // MARK: NSTextStorageDelegate —— 每次编辑同步平移锚点（sticky）
    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        editGeneration &+= 1
        let editStart = editedRange.location
        let oldEnd = editedRange.location + editedRange.length - delta   // 被替换区间的旧末端
        // 整篇替换（加载/格式化整体回写）→ 不做增量，全交给对账，避免整屏闪“已改”
        if editStart == 0 && editedRange.length == textStorage.length && oldEnd != editedRange.length {
            dirtyOffsets = []
            pushToView(); scheduleRecompute(); return
        }
        dirtyOffsets = Self.shift(dirtyOffsets, editStart: editStart, oldEnd: oldEnd, delta: delta)
        // 即时点亮正在编辑的行（行首偏移）→ 打字即见竖条，无需等对账
        let ns = textStorage.string as NSString
        if editStart <= ns.length {
            dirtyOffsets.insert(ns.lineRange(for: NSRange(location: editStart, length: 0)).location)
        }
        pushToView()
        scheduleRecompute()
    }

    /// 把偏移集合按一次编辑 (editStart, oldEnd, delta) 平移；落在被替换区间内的锚点丢弃（交给对账重建）。
    private static func shift(_ offsets: Set<Int>, editStart: Int, oldEnd: Int, delta: Int) -> Set<Int> {
        var out = Set<Int>()
        for o in offsets {
            if o <= editStart { out.insert(o) }
            else if o >= oldEnd { out.insert(o + delta) }
        }
        return out
    }

    // MARK: 后台权威对账
    private func scheduleRecompute() {
        recomputeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.runRecompute() }
        recomputeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }
    private func recomputeNow() { recomputeWork?.cancel(); runRecompute() }
    private func runRecompute() {
        guard let tv = controller?.textView else { return }
        let snapshot = tv.string
        let gen = editGeneration
        let base = baselineLines
        recomputeToken &+= 1
        let token = recomputeToken
        diffQueue.async { [weak self] in
            let dirty = Self.computeOffsets(curText: snapshot, baselineLines: base)
            DispatchQueue.main.async {
                guard let self, self.recomputeToken == token, self.editGeneration == gen else { return }  // 过期/已被新编辑取代 → 丢弃
                self.dirtyOffsets = dirty
                self.pushToView()
            }
        }
    }

    private func pushToView() {
        barView?.dirtyOffsets = dirtyOffsets
    }

    private static func splitLines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    /// diff（hunk 分类，与 VSCode 一致）→ 当前文本的「行首 UTF-16 偏移」锚点（竖条 = Added∪Modified 行首）。
    /// 纯删除不画任何标记（用户选择去掉删除三角）。偏移用 UTF-16 前缀和（与 NSTextStorage 同坐标）。
    private static func computeOffsets(curText: String, baselineLines: [String]) -> Set<Int> {
        let curLines = splitLines(curText)
        let diff = curLines.difference(from: baselineLines)
        var changed = Set<Int>()     // Added/Modified 当前行号
        if !diff.isEmpty {
            var removeOffsets: [Int] = [], insertOffsets: [Int] = []
            for change in diff {
                switch change {
                case let .remove(o, _, _): removeOffsets.append(o)
                case let .insert(o, _, _): insertOffsets.append(o)
                }
            }
            let delRuns = collapseRuns(removeOffsets)
            let insRuns = collapseRuns(insertOffsets)
            var di = 0, ii = 0, delta = 0
            while di < delRuns.count || ii < insRuns.count {
                let d = di < delRuns.count ? delRuns[di] : nil
                let i = ii < insRuns.count ? insRuns[ii] : nil
                if let d, let i, i.start <= d.start + delta {
                    if i.start == d.start + delta {                      // Modified
                        for ln in i.start ..< (i.start + i.len) { changed.insert(ln) }
                        delta += i.len - d.len; di += 1; ii += 1
                    } else {                                             // Added（删除前）
                        for ln in i.start ..< (i.start + i.len) { changed.insert(ln) }
                        delta += i.len; ii += 1
                    }
                } else if let d, (i == nil || d.start + delta < i!.start) {  // Deleted（纯删除：仅推进 delta，不画标记）
                    delta -= d.len; di += 1
                } else if let i {                                        // Added（收尾）
                    for ln in i.start ..< (i.start + i.len) { changed.insert(ln) }
                    delta += i.len; ii += 1
                }
            }
        }
        // 行号 → 行首 UTF-16 偏移（前缀和）。starts[k] = 第 k 行行首偏移。
        var starts = [Int](repeating: 0, count: curLines.count + 1)
        for k in 0..<curLines.count { starts[k + 1] = starts[k] + curLines[k].utf16.count + 1 }
        var dirty = Set<Int>()
        for ln in changed where ln >= 0 && ln < curLines.count { dirty.insert(starts[ln]) }
        return dirty
    }

    private static func collapseRuns(_ xs: [Int]) -> [(start: Int, len: Int)] {
        var out: [(start: Int, len: Int)] = []
        for x in xs.sorted() {
            if let last = out.last, x == last.start + last.len { out[out.count - 1].len += 1 }
            else { out.append((x, 1)) }
        }
        return out
    }

    private func install() {
        guard let controller, let scrollView = controller.scrollView, controller.textView != nil else { return }
        barView?.removeFromSuperview()
        let v = ChangeBarView()
        v.controller = controller
        v.dirtyOffsets = dirtyOffsets
        v.onResize = { [weak self] in self?.updateFrame() }   // hover 时撑宽/收窄
        // 加在 gutter 之后 → z 序在 gutter 之上；for:.horizontal 与 gutter 一致（横滚不动、纵滚随内容）
        scrollView.addFloatingSubview(v, for: .horizontal)
        barView = v
        updateFrame()

        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        scrollView.contentView.postsFrameChangedNotifications = true
        let tv = controller.textView
        let clip = scrollView.contentView
        // textView 帧变（内容/文档宽高变）+ 视口帧变（窗口缩放）都要重定位
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: tv, queue: .main) { [weak self] _ in self?.updateFrame() })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in self?.updateFrame() })
    }

    /// 高度=文档高、原点 y 跟随 textView；宽度=平时窄条、hover 时整视口宽（见 ChangeBarView.desiredWidth）。
    private func updateFrame() {
        guard let controller, let v = barView,
              let tv = controller.textView, let sv = controller.scrollView else { return }
        v.frame = NSRect(x: 0,
                         y: tv.frame.origin.y - sv.contentInsets.top,
                         width: v.desiredWidth(viewport: sv.contentSize.width),
                         height: tv.frame.height + 10)
        v.needsDisplay = true
    }

    func destroy() {
        recomputeWork?.cancel()
        controller?.textView?.removeStorageDelegate(self)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        barView?.removeFromSuperview()
        barView = nil
    }
}

/// change hunk gutter indicator：每个「连续未保存改动区间(hunk)」= 一颗竖向圆角蓝胶囊
/// （内部浅、外圈稍深细边框，半镂空感）。hover 时该 hunk 叠一层淡蓝横向背景做范围反馈、胶囊略放大。
/// 仅最左缘窄带(stripWidth)接收事件，其余区域点击穿透，不影响行号栏折叠/正文选择。
private final class ChangeBarView: NSView {
    weak var controller: TextViewController?
    /// 各「已改行」行首的 UTF-16 偏移（当前文本坐标）→ 绘制时**实时**经 textLineForOffset 映射为行位置，故永不错位。
    var dirtyOffsets: Set<Int> = [] {
        didSet { if dirtyOffsets != oldValue { needsDisplay = true } }
    }
    private let barColor = NSColor(hex: 0x1E90FF)
    private let stripWidth: CGFloat = 14          // 最左缘悬停感应带
    private let capsuleX: CGFloat = 10             // 胶囊左缘
    private let restingW: CGFloat = 5             // 胶囊静止宽
    private let hoverW: CGFloat = 7               // 胶囊张开宽
    /// 平时浮层只占行号栏这一窄条 → 滚动时正文走 NSScrollView 的快速拷贝复用，不被整宽浮层每帧重渲染拖累；
    /// 仅 hover 时经 onResize 临时撑到整视口宽以画横向背景。
    private var narrowWidth: CGFloat { capsuleX + hoverW + 6 }
    var onResize: (() -> Void)?
    func desiredWidth(viewport: CGFloat) -> CGFloat { animHunk != nil ? viewport : narrowWidth }

    private var hoveredHunk: Int? {               // 当前悬停的 hunk（来自鼠标）
        didSet {
            guard hoveredHunk != oldValue else { return }
            if let h = hoveredHunk {
                animHunk = h
                onResize?()                       // 撑到整宽以画背景
                animate(to: 1)                    // 张开
            } else {
                animate(to: 0) { [weak self] in
                    self?.animHunk = nil
                    self?.onResize?()             // 收回窄条
                    self?.needsDisplay = true
                }
            }
        }
    }
    private var animHunk: Int?                     // 正在播动画的 hunk（收拢动画期间仍保留以便绘制）
    private var hoverProgress: CGFloat = 0 {       // 0=静止 1=完全展开（胶囊左右张开 + 背景淡入）
        didSet { needsDisplay = true }
    }
    private var anim: Timer?

    override var isFlipped: Bool { true }

    /// 用 smoothstep 缓动把 hoverProgress 推到 target（0/1），加进 .common 模式 → 滚动/拖拽时也走动画。
    private func animate(to target: CGFloat, completion: (() -> Void)? = nil) {
        anim?.invalidate()
        if hoverProgress == target { completion?(); return }
        let start = hoverProgress
        let begin = ProcessInfo.processInfo.systemUptime
        let duration = 0.16
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let raw = min(1.0, (ProcessInfo.processInfo.systemUptime - begin) / duration)
            let eased = CGFloat(raw * raw * (3 - 2 * raw))
            self.hoverProgress = start + (target - start) * eased
            if raw >= 1 { self.hoverProgress = target; t.invalidate(); completion?() }
        }
        RunLoop.main.add(timer, forMode: .common)
        anim = timer
    }

    /// 只让最左缘窄带“吃”事件（hover/点击），其余穿透到行号栏/正文。
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), local.x <= stripWidth else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .inVisibleRect：跟踪区自动等于可见区，免手算 rect。之前用 bounds.height 在 frame 后置时为 0
        // → 跟踪区为空 → hover 永不触发，这是“悬停没反应”的根因。
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInActiveApp],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { updateHovered(event) }
    override func mouseMoved(with event: NSEvent) { updateHovered(event) }
    override func mouseExited(with event: NSEvent) { hoveredHunk = nil }

    /// 仅当光标落在最左缘窄带(stripWidth) 且压在某个 hunk 的竖直范围内时，才高亮该 hunk。
    private func updateHovered(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard p.x <= stripWidth else { hoveredHunk = nil; return }
        hoveredHunk = hunks().firstIndex { p.y >= $0.top && p.y <= $0.bottom }
    }

    /// 每个连续段（hunk）的竖直范围（文档坐标，与 textView 同空间）。
    /// 偏移锚点 → 实时行位置（textLineForOffset），按**行号**升序后把相邻行并成一个 hunk。
    private func hunks() -> [(top: CGFloat, bottom: CGFloat)] {
        guard let lm = controller?.textView?.layoutManager else { return [] }
        var byIndex: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
        for off in dirtyOffsets {
            guard let pos = lm.textLineForOffset(off) else { continue }
            byIndex[pos.index] = (pos.yPos, pos.yPos + pos.height)
        }
        var result: [(top: CGFloat, bottom: CGFloat)] = []
        var have = false, prevIdx = -2
        var top: CGFloat = 0, bottom: CGFloat = 0
        for idx in byIndex.keys.sorted() {
            let info = byIndex[idx]!
            if have && idx == prevIdx + 1 {
                top = min(top, info.top); bottom = max(bottom, info.bottom)
            } else {
                if have { result.append((top, bottom)) }
                top = info.top; bottom = info.bottom; have = true
            }
            prevIdx = idx
        }
        if have { result.append((top, bottom)) }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !dirtyOffsets.isEmpty else { return }
        let centerX = capsuleX + restingW / 2       // 以静止中心为锚 → 左右对称张开

        for (i, hunk) in hunks().enumerated() {
            let h = hunk.bottom - hunk.top
            let p = (i == animHunk) ? hoverProgress : 0     // 仅动画中的 hunk 用进度
            let w = restingW + (hoverW - restingW) * p
            let cap = NSRect(x: centerX - w / 2, y: hunk.top, width: w, height: h)

            // hover 横向背景：与胶囊同圆角、自胶囊右缘起、无缝一体。
            // 做法：背景圆角矩形从胶囊「左缘」起画（半径同胶囊），随后把胶囊覆在其左端 →
            // 浅蓝填充实际从胶囊右缘显现，二者共用左侧圆角，看起来是一个整体。
            if p > 0.01 {
                let band = NSRect(x: cap.minX, y: hunk.top, width: max(0, bounds.width - cap.minX), height: h)
                let bp = NSBezierPath(roundedRect: band, xRadius: w / 2, yRadius: w / 2)
                barColor.withAlphaComponent(0.09 * p).setFill(); bp.fill()
                barColor.withAlphaComponent(0.40 * p).setStroke(); bp.lineWidth = 1; bp.stroke()
            }

            // 圆角胶囊（覆在背景左端）：放大只变宽，颜色/边框与静止时完全一致（不变亮、不填满）。
            guard i == animHunk || cap.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: cap, xRadius: w / 2, yRadius: w / 2)
            barColor.withAlphaComponent(0.5).setFill()
            path.fill()
            barColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

extension EditorTheme {
    /// 从 termo 的 ThemeColors + VSCode Dark+/Light+ 风配色映射出 EditorTheme（颜色均为 NSColor）。
    static func termo(colors: ThemeColors, isDark: Bool) -> EditorTheme {
        let fg = NSColor(hex: colors.termFg)
        let bg = NSColor(hex: colors.termBg)

        let comment, string, number, keyword, type, function, variable, constant: NSColor
        if isDark {
            comment  = NSColor(hex: 0x6a9955)
            string   = NSColor(hex: 0xce9178)
            number   = NSColor(hex: 0xb5cea8)
            keyword  = NSColor(hex: 0x569cd6)
            type     = NSColor(hex: 0x4ec9b0)
            function = NSColor(hex: 0xdcdcaa)
            variable = NSColor(hex: 0x9cdcfe)
            constant = NSColor(hex: 0x4fc1ff)
        } else {
            comment  = NSColor(hex: 0x008000)
            string   = NSColor(hex: 0xa31515)
            number   = NSColor(hex: 0x098658)
            keyword  = NSColor(hex: 0x0000ff)
            type     = NSColor(hex: 0x267f99)
            function = NSColor(hex: 0x795e26)
            variable = NSColor(hex: 0x001080)
            constant = NSColor(hex: 0x0070c1)
        }

        return EditorTheme(
            text:           Attribute(color: fg),
            insertionPoint: NSColor(hex: colors.termCaret),
            invisibles:     Attribute(color: fg.withAlphaComponent(0.25)),
            background:     bg,
            lineHighlight:  fg.withAlphaComponent(0.06),
            selection:      NSColor(hex: colors.termSelection),
            keywords:       Attribute(color: keyword, bold: true),
            commands:       Attribute(color: function),   // 函数调用类
            types:          Attribute(color: type),
            attributes:     Attribute(color: variable),
            variables:      Attribute(color: variable),
            values:         Attribute(color: constant),
            numbers:        Attribute(color: number),
            strings:        Attribute(color: string),
            characters:     Attribute(color: string),
            comments:       Attribute(color: comment, italic: true)
        )
    }
}
