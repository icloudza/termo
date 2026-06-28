import Foundation
import Security

/// 密钥元数据的 JSON 持久化（~/Library/Application Support/termo/keys.json）。私钥不在此（见 KeyKeychain）。
enum KeyStore {
    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var url: URL { dir.appendingPathComponent("keys.json") }

    static func load() -> [SSHKey] {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([SSHKey].self, from: data) else { return [] }
        return keys
    }

    static func save(_ keys: [SSHKey]) {
        if let data = try? JSONEncoder().encode(keys) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 私钥本体的 Keychain 存取——私钥只进系统钥匙串，绝不写入磁盘 JSON。
/// 全部私钥合并为「单条」条目（id → PEM），读取一次即拿到全部，把授权弹窗降到一次（对齐 HostKeychain 做法）。
enum KeyKeychain {
    private static let service = "com.termo.sshPrivateKeys"
    private static let account = "all"

    static func loadAll() -> [String: String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func saveAll(_ map: [String: String]) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !map.isEmpty, let data = try? JSONEncoder().encode(map) else { return }
        var q = base
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    static func privateKey(_ id: String) -> String? { loadAll()[id] }

    static func set(_ id: String, _ pem: String) {
        var m = loadAll(); m[id] = pem; saveAll(m)
    }

    static func remove(_ id: String) {
        var m = loadAll(); m.removeValue(forKey: id); saveAll(m)
    }
}
