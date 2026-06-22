import AppKit
import SwiftUI

@main
struct TermoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 720, minHeight: 440)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        HStack(spacing: 0) {
            ActivityBar(model: model)
            Sidebar(model: model)
            VStack(spacing: 0) {
                TabBar(model: model)
                Workspace(model: model)
                    .padding([.leading, .top], 3)
            }
            .background(Pal.mantle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.base)
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
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
