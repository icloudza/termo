import Foundation
import Security

/// WebDAV 同步配置持久化：地址 / 用户名 / 远程路径 / 上次同步时间存 UserDefaults。
/// WebDAV 登录密码与主密码都不进 UserDefaults——密码见 SyncKeychain，主密码不持久化。
enum SyncConfigStore {
    private static let d = UserDefaults.standard
    private static let baseURLKey = "syncWebDAVBaseURL"
    private static let usernameKey = "syncWebDAVUsername"
    private static let remotePathKey = "syncWebDAVRemotePath"
    private static let lastSyncKey = "syncLastSyncAt"

    static let defaultRemotePath = "termo/termo-sync.json"

    static var baseURL: String {
        get { d.string(forKey: baseURLKey) ?? "" }
        set { d.set(newValue, forKey: baseURLKey) }
    }
    static var username: String {
        get { d.string(forKey: usernameKey) ?? "" }
        set { d.set(newValue, forKey: usernameKey) }
    }
    static var remotePath: String {
        get { d.string(forKey: remotePathKey) ?? defaultRemotePath }
        set { d.set(newValue, forKey: remotePathKey) }
    }
    static var lastSyncAt: Date? {
        get { d.object(forKey: lastSyncKey) as? Date }
        set { d.set(newValue, forKey: lastSyncKey) }
    }

    /// 备份文件里记录的本机名（仅用于展示来源，不含任何身份信息）。
    static var deviceName: String {
        ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }
}

/// WebDAV 登录密码的 Keychain 存取——密码只进系统钥匙串，绝不写入磁盘明文。
enum SyncKeychain {
    private static let service = "com.termo.webdavPassword"
    private static let account = "default"

    static func loadPassword() -> String {
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
            let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s
    }

    static func savePassword(_ password: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !password.isEmpty, let data = password.data(using: .utf8) else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let updateStatus = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
