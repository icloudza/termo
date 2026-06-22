import SwiftUI

enum Section: Hashable {
    case hosts, files, keys, snippets, settings
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

struct Host: Identifiable {
    let id: String
    let name: String
    let addr: String
    let group: String
    let status: HostStatus
    let os: String

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
