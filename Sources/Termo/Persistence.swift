import Foundation
import Security

/// 用 OpenSSH 内置的 SSH_ASKPASS 机制喂密码，无需第三方 sshpass。
/// 助手脚本本身不含密码（密码经 TERMO_SSH_PASSWORD 环境变量传入），
/// 配合 SSH_ASKPASS_REQUIRE=force（OpenSSH 8.4+）让 ssh 无论有无 TTY 都调用它读密码。
enum SSHAskpass {
    static let passwordEnvKey = "TERMO_SSH_PASSWORD"

    /// 确保助手脚本存在且可执行，返回其绝对路径。脚本本身不含任何密码。
    private static func ensureHelper() -> String? {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$\(passwordEnvKey)\"\n"
        do {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current != script {
                try script.write(to: url, atomically: true, encoding: .utf8)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return nil
        }
        return url.path
    }

    /// 要追加到 ssh 进程环境的键值，让 ssh 用 askpass 自动获取密码。
    /// 返回 nil 表示助手脚本创建失败（无法启用自动密码）。
    static func envVars(password: String) -> [String: String]? {
        guard let helper = ensureHelper() else { return nil }
        return [
            "SSH_ASKPASS": helper,
            "SSH_ASKPASS_REQUIRE": "force",
            passwordEnvKey: password,
        ]
    }
}

/// 主机密码的 Keychain 存取——密码只进系统钥匙串，绝不写入磁盘 JSON。
enum HostKeychain {
    private static let service = "com.termo.hostPassword"

    static func save(_ password: String, for hostId: String) {
        delete(hostId)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
            kSecValueData as String: data,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(_ hostId: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func delete(_ hostId: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
        ]
        SecItemDelete(q as CFDictionary)
    }
}

/// 主机列表与会话历史的 JSON 持久化（~/Library/Application Support/termo/）。
enum HostStore {
    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var hostsURL: URL { dir.appendingPathComponent("hosts.json") }
    private static var sessionsURL: URL { dir.appendingPathComponent("sessions.json") }
    private static var forwardsURL: URL { dir.appendingPathComponent("forwards.json") }

    static func loadHosts() -> [Host] {
        guard let data = try? Data(contentsOf: hostsURL),
              var hosts = try? JSONDecoder().decode([Host].self, from: data) else { return [] }
        // JSON 不含密码，从 Keychain 回填（SSH 或 RDP，二者其一）
        for i in hosts.indices {
            let pw = HostKeychain.load(hosts[i].id)
            if hosts[i].ssh != nil {
                hosts[i].ssh?.password = pw
            } else if hosts[i].rdp != nil {
                hosts[i].rdp?.password = pw
            }
        }
        return hosts
    }

    static func saveHosts(_ hosts: [Host]) {
        let hosts = hosts.filter { !$0.isMock }   // 模拟演示主机不落盘
        // 密码进 Keychain；JSON 由 SSHConnection.CodingKeys 排除了 password 字段
        for h in hosts {
            if let ssh = h.ssh { HostKeychain.save(ssh.password, for: h.id) }
            else if let rdp = h.rdp { HostKeychain.save(rdp.password, for: h.id) }
        }
        if let data = try? JSONEncoder().encode(hosts) {
            try? data.write(to: hostsURL, options: .atomic)
        }
    }

    static func loadSessions() -> [SessionEvent] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let s = try? JSONDecoder().decode([SessionEvent].self, from: data) else { return [] }
        return s
    }

    static func saveSessions(_ sessions: [SessionEvent]) {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    static func loadForwards() -> [ForwardRule] {
        guard let data = try? Data(contentsOf: forwardsURL),
              let f = try? JSONDecoder().decode([ForwardRule].self, from: data) else { return [] }
        return f
    }

    static func saveForwards(_ forwards: [ForwardRule]) {
        if let data = try? JSONEncoder().encode(forwards) {
            try? data.write(to: forwardsURL, options: .atomic)
        }
    }
}
