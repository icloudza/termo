import Foundation

/// 一条已信任的 RDP 服务器证书（按 host:port 唯一；证书更换后原地更新指纹）。
struct RDPTrustedCert: Codable, Identifiable, Hashable {
    let host: String
    let port: Int
    var fingerprint: String
    var subject: String?
    var issuer: String?
    var trustedAt: Date

    var id: String { "\(host):\(port)" }
}

/// RDP 证书信任库：用户在首连弹窗里勾选「始终信任此电脑」后写入，作为信任判定的**唯一来源**
/// （不依赖 FreeRDP 自带 known_hosts —— 底层每次都回调询问，由本库决定静默放行还是弹窗）。
/// JSON 落 ~/Library/Application Support/termo/rdp_trusted_certs.json；证书指纹非机密，明文落盘即可。
/// 读写均在主线程（首连 delegate 与设置页都在主线程）。
final class RDPCertTrustStore: ObservableObject {
    static let shared = RDPCertTrustStore()

    @Published private(set) var entries: [RDPTrustedCert]

    private init() { entries = Self.load() }

    /// 该 host:port 是否已永久信任且指纹一致。指纹不一致视为不可信 → 触发「证书已更改」复核弹窗。
    func isTrusted(host: String, port: Int, fingerprint: String) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return entries.contains { $0.host == host && $0.port == port && $0.fingerprint == fingerprint }
    }

    /// 写入/更新信任（按 host:port 覆盖；证书更换即更新指纹与时间）。
    func trust(host: String, port: Int, fingerprint: String, subject: String?, issuer: String?) {
        let cert = RDPTrustedCert(host: host, port: port, fingerprint: fingerprint,
                                  subject: subject, issuer: issuer, trustedAt: Date())
        if let i = entries.firstIndex(where: { $0.host == host && $0.port == port }) {
            entries[i] = cert
        } else {
            entries.append(cert)
        }
        persist()
    }

    /// 撤销某条信任（设置页「已信任主机」管理用）；撤销后该主机下次连接会重新弹证书询问。
    func revoke(_ id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    // MARK: - 持久化

    private static var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("rdp_trusted_certs.json")
    }

    private static func load() -> [RDPTrustedCert] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([RDPTrustedCert].self, from: data) else { return [] }
        return items
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
