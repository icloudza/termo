import SwiftUI

enum Section: Hashable {
    case hosts, files, keys, snippets, settings
}

enum SettingsTab: String, CaseIterable, Hashable {
    case general = "通用"
    case appearance = "外观"
    case terminal = "终端"
    case keys = "快捷键"
    case about = "关于"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .terminal: return "terminal"
        case .keys: return "command"
        case .about: return "info.circle"
        }
    }
}

enum TabKind {
    case overview, terminal, files
}

struct TabItem: Identifiable {
    let id: Int
    let kind: TabKind
    var title: String
    var hostId: String?
}

enum HostStatus {
    case online, offline, unknown
}

/// 一台主机的 SSH 连接配置，用于构建真实的 ssh 命令。
struct SSHConnection {
    var user: String = "root"
    var host: String = ""
    var port: Int = 22
    var authMethod: AuthMethod = .password
    var password: String = ""
    var encoding: String = ""
    var hostKeyAlgos: String = ""
    var ciphers: String = ""
    var kexAlgos: String = ""
    var proxyURL: String = ""
    var disableProxy: Bool = false
    var timeoutMs: Int = 10000
    var heartbeatMs: Int = 5000
    var initialCommand: String = ""
    var defaultPath: String = "~"

    var usesPassword: Bool {
        authMethod == .password && !password.isEmpty
    }

    /// 构建传给 ssh 的参数（不含 ssh 本身）。verbose 用于测试连接以解析流程。
    func sshArguments(verbose: Bool = false) -> [String] {
        var a: [String] = []
        if verbose { a.append("-v") }
        a += ["-o", "StrictHostKeyChecking=accept-new"]
        a += ["-o", "UserKnownHostsFile=\(NSHomeDirectory())/.ssh/known_hosts"]
        a += ["-o", "NumberOfPasswordPrompts=1"]
        a += ["-p", String(port)]
        if timeoutMs > 0 { a += ["-o", "ConnectTimeout=\(max(1, timeoutMs / 1000))"] }
        if heartbeatMs > 0 { a += ["-o", "ServerAliveInterval=\(max(1, heartbeatMs / 1000))"] }
        if !ciphers.isEmpty { a += ["-c", ciphers] }
        if !kexAlgos.isEmpty { a += ["-o", "KexAlgorithms=\(kexAlgos)"] }
        if !hostKeyAlgos.isEmpty { a += ["-o", "HostKeyAlgorithms=\(hostKeyAlgos)"] }
        if !disableProxy, !proxyURL.isEmpty, let pc = proxyCommand() {
            a += ["-o", "ProxyCommand=\(pc)"]
        }
        a += ["\(user)@\(host)"]
        return a
    }

    /// 把 socks/http 代理 URL 转换为 ssh ProxyCommand（基于 nc）。
    private func proxyCommand() -> String? {
        guard let comps = URLComponents(string: proxyURL),
              let scheme = comps.scheme?.lowercased(),
              let phost = comps.host, let pport = comps.port else { return nil }
        switch scheme {
        case "socks5", "socks5h": return "nc -X 5 -x \(phost):\(pport) %h %p"
        case "socks4": return "nc -X 4 -x \(phost):\(pport) %h %p"
        case "http", "https": return "nc -X connect -x \(phost):\(pport) %h %p"
        default: return nil
        }
    }
}

struct Host: Identifiable {
    let id: String
    let name: String
    let addr: String
    let group: String
    let status: HostStatus
    let os: String
    var port: Int = 22
    var ssh: SSHConnection? = nil

    var statusColor: Color {
        switch status {
        case .online: return Pal.green
        case .offline: return Pal.overlay
        case .unknown: return Pal.yellow
        }
    }

    static let mock: [Host] = [
        Host(id: "web-prod-01", name: "web-prod-01", addr: "root@192.168.1.20", group: "生产环境", status: .online, os: "Ubuntu 22.04"),
        Host(id: "db-prod-01", name: "db-prod-01", addr: "root@192.168.1.21", group: "生产环境", status: .online, os: "Debian 12"),
        Host(id: "homelab", name: "homelab", addr: "lxc@10.0.0.5", group: "个人", status: .offline, os: "Arch Linux"),
        Host(id: "vps-tokyo", name: "vps-tokyo", addr: "ubuntu@vps.example.jp", group: "个人", status: .unknown, os: "Ubuntu 24.04"),
    ]
}
