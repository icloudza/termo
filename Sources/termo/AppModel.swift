import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var section: Section = .hosts
    @Published var query: String = ""
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: Int? = nil

    let hosts: [Host] = Host.mock

    // 终端 NSView 实例缓存：切换标签时复用，会话不丢失（进程在后台继续跑）
    private var terminals: [Int: LocalProcessTerminalView] = [:]
    private var nextTabId = 1
    private var terminalCount = 0

    var activeHostId: String? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })?.hostId
    }

    func host(_ id: String?) -> Host? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    // ---------- 终端 ----------
    func terminalView(for tabId: Int) -> LocalProcessTerminalView {
        if let tv = terminals[tabId] { return tv }
        let tv = makeTerminal()
        terminals[tabId] = tv
        return tv
    }

    private func makeTerminal() -> LocalProcessTerminalView {
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        tv.nativeBackgroundColor = NSColor(hex: 0x1e1e2e)
        tv.nativeForegroundColor = NSColor(hex: 0xcdd6f4)
        tv.caretColor = NSColor(hex: 0xcba6f7)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
        if !lang.uppercased().contains("UTF-8") {
            env.append("LANG=en_US.UTF-8")
        }
        tv.startProcess(executable: shell, args: ["-l"], environment: env)
        return tv
    }

    // ---------- 标签操作 ----------
    func openLocalTerminal() {
        terminalCount += 1
        addTab(.terminal, title: "本地终端 \(terminalCount)", hostId: nil)
    }

    func openHost(_ host: Host) {
        if let existing = tabs.first(where: { $0.kind == .overview && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        addTab(.overview, title: host.name, hostId: host.id)
    }

    func openHostTerminal(_ host: Host) {
        addTab(.terminal, title: host.name, hostId: host.id)
    }

    private func addTab(_ kind: TabKind, title: String, hostId: String?) {
        let id = nextTabId
        nextTabId += 1
        tabs.append(TabItem(id: id, kind: kind, title: title, hostId: hostId))
        activeTabId = id
    }

    func selectTab(_ id: Int) {
        activeTabId = id
    }

    func closeTab(_ id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        terminals.removeValue(forKey: id)
        if activeTabId == id {
            activeTabId = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
    }
}
