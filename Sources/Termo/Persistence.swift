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
/// 所有主机密码合并为「单条」钥匙串条目（combined*），读取一次即拿到全部，把授权弹窗从「每主机一次」降到「一次」。
/// 旧的逐主机条目（service）仅保留用于迁移读取与删除清理。
enum HostKeychain {
    private static let service = "com.termo.hostPassword"            // 旧：逐主机一条
    private static let combinedService = "com.termo.hostPasswords"   // 新：合并为一条
    private static let combinedAccount = "all"

    /// 读取合并条目（全部主机密码）。一次访问 → 最多一次授权弹窗。
    static func loadAll() -> [String: String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: combinedService,
            kSecAttrAccount as String: combinedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    /// 覆盖写入合并条目（map 为空则删除该条目）。
    static func saveAll(_ map: [String: String]) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: combinedService,
            kSecAttrAccount as String: combinedAccount,
        ]
        SecItemDelete(base as CFDictionary)
        guard !map.isEmpty, let data = try? JSONEncoder().encode(map) else { return }
        var q = base
        q[kSecValueData as String] = data
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
        // JSON 不含密码，从 Keychain 回填：优先读合并条目；命中不到再兜底读旧逐主机条目（迁移）。
        var combined = HostKeychain.loadAll()
        var migrated = false
        for i in hosts.indices {
            let id = hosts[i].id
            var pw = combined[id]
            if pw == nil {
                let legacy = HostKeychain.load(id)   // 旧逐主机条目兜底
                if !legacy.isEmpty { pw = legacy; combined[id] = legacy; migrated = true }
            }
            if let pw {
                if hosts[i].ssh != nil { hosts[i].ssh?.password = pw }
                else if hosts[i].rdp != nil { hosts[i].rdp?.password = pw }
            }
        }
        if migrated { HostKeychain.saveAll(combined) }   // 旧条目并入合并条目，下次起只需一次授权
        return hosts
    }

    static func saveHosts(_ hosts: [Host]) {
        let hosts = hosts.filter { !$0.isMock }   // 模拟演示主机不落盘
        // 密码合并写入单条 Keychain 条目；JSON 由 SSHConnection.CodingKeys 排除了 password 字段
        var pwMap: [String: String] = [:]
        for h in hosts {
            if let ssh = h.ssh, !ssh.password.isEmpty { pwMap[h.id] = ssh.password }
            else if let rdp = h.rdp, !rdp.password.isEmpty { pwMap[h.id] = rdp.password }
        }
        HostKeychain.saveAll(pwMap)
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
