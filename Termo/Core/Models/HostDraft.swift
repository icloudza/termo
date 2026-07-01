import SwiftUI

/// OpenSSH 算法与编码选项。空字符串表示「默认（自动协商）」。
enum SSHOptions {
    static let encodings: [(value: String, label: String)] = [
        ("", String(localized: "默认（UTF-8）")),
        ("UTF-8", "UTF-8"), ("GBK", "GBK"), ("GB2312", "GB2312"), ("GB18030", "GB18030"),
        ("Big5", String(localized: "Big5 (繁体)")), ("Shift_JIS", String(localized: "Shift_JIS (日文)")), ("EUC-JP", String(localized: "EUC-JP (日文)")),
        ("EUC-KR", String(localized: "EUC-KR (韩文)")), ("KOI8-R", String(localized: "KOI8-R (俄文)")),
        ("ISO-8859-1", String(localized: "ISO-8859-1 (西欧)")), ("ISO-8859-15", "ISO-8859-15"),
        ("Windows-1251", String(localized: "Windows-1251 (西里尔)")), ("Windows-1252", "Windows-1252"),
        ("ASCII", "US-ASCII"),
    ]

    static let hostKeyAlgos: [(value: String, label: String)] = [
        ("", String(localized: "默认（自动协商）")),
        ("ssh-ed25519", "ssh-ed25519"),
        ("rsa-sha2-512", "rsa-sha2-512"),
        ("rsa-sha2-256", "rsa-sha2-256"),
        ("ecdsa-sha2-nistp256", "ecdsa-sha2-nistp256"),
        ("ecdsa-sha2-nistp384", "ecdsa-sha2-nistp384"),
        ("ecdsa-sha2-nistp521", "ecdsa-sha2-nistp521"),
        ("ssh-rsa", String(localized: "ssh-rsa (旧)")),
        ("ssh-dss", String(localized: "ssh-dss (旧)")),
    ]

    static let ciphers: [(value: String, label: String)] = [
        ("", String(localized: "默认（自动协商）")),
        ("chacha20-poly1305@openssh.com", "chacha20-poly1305"),
        ("aes256-gcm@openssh.com", "aes256-gcm"),
        ("aes128-gcm@openssh.com", "aes128-gcm"),
        ("aes256-ctr", "aes256-ctr"),
        ("aes192-ctr", "aes192-ctr"),
        ("aes128-ctr", "aes128-ctr"),
        ("aes256-cbc", String(localized: "aes256-cbc (旧)")),
        ("aes128-cbc", String(localized: "aes128-cbc (旧)")),
        ("3des-cbc", String(localized: "3des-cbc (旧)")),
    ]

    static let kexAlgos: [(value: String, label: String)] = [
        ("", String(localized: "默认（自动协商）")),
        ("curve25519-sha256", "curve25519-sha256"),
        ("curve25519-sha256@libssh.org", "curve25519-sha256@libssh.org"),
        ("ecdh-sha2-nistp256", "ecdh-sha2-nistp256"),
        ("ecdh-sha2-nistp384", "ecdh-sha2-nistp384"),
        ("ecdh-sha2-nistp521", "ecdh-sha2-nistp521"),
        ("diffie-hellman-group-exchange-sha256", "dh-group-exchange-sha256"),
        ("diffie-hellman-group16-sha512", "dh-group16-sha512"),
        ("diffie-hellman-group14-sha256", "dh-group14-sha256"),
        ("diffie-hellman-group14-sha1", String(localized: "dh-group14-sha1 (旧)")),
    ]
}

enum AuthMethod: String, CaseIterable, Hashable, Codable {
    case password = "密码"
    case key = "密钥"
    case ask = "每次询问"           // 每次连接时弹窗输入本次密码，不保存任何凭证

    // rawValue 已持久化进主机，不能改；显示用本地化 label。
    var label: String {
        switch self {
        case .password: return String(localized: "密码")
        case .key: return String(localized: "密钥")
        case .ask: return String(localized: "每次询问")
        }
    }
}

enum HostFormSection: String, CaseIterable, Hashable {
    case basic = "基本信息"
    case connection = "连接设置"
    case initial = "初始选项"
    case proxy = "代理设置"
    case advanced = "高级设置"

    var label: String {
        switch self {
        case .basic: return String(localized: "基本信息")
        case .connection: return String(localized: "连接设置")
        case .initial: return String(localized: "初始选项")
        case .proxy: return String(localized: "代理设置")
        case .advanced: return String(localized: "高级设置")
        }
    }

    var icon: String {
        switch self {
        case .basic: return "server.rack"
        case .connection: return "network"
        case .initial: return "terminal"
        case .proxy: return "arrow.triangle.swap"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

/// 新增/编辑主机的表单数据。
@MainActor
final class HostDraft: ObservableObject {
    // 基本信息
    @Published var group = ""
    @Published var name = ""
    @Published var address = ""
    @Published var authMethod: AuthMethod = .ask   // 新增主机默认「每次询问」（连接时弹窗输入，不存凭证）
    @Published var user = "root"
    @Published var password = ""
    @Published var keyPath = ""        // 私钥文件路径（认证方式为「密钥」时使用）
    @Published var keyId = ""          // 关联密钥库的密钥 id（非空则用库密钥，优先于 keyPath）
    @Published var notes = ""

    // 连接设置
    @Published var timeout = "10000"
    @Published var heartbeat = "5000"

    // 初始选项
    @Published var defaultPath = "~"
    @Published var initialCommand = ""

    // 代理设置
    @Published var disableProxy = false
    @Published var proxyURL = ""

    // 高级设置
    @Published var encoding = ""
    @Published var hostKeyAlgos = ""
    @Published var ciphers = ""
    @Published var kexAlgos = ""

    // 端口
    @Published var port = "22"

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var resolvedGroup: String {
        let g = group.trimmingCharacters(in: .whitespaces)
        return g.isEmpty ? String(localized: "未分组") : g
    }

    /// 从已有主机回填表单（编辑模式）。
    func load(from host: Host) {
        name = host.name
        group = host.group
        notes = host.notes
        guard let s = host.ssh else { return }
        user = s.user
        address = s.host
        port = String(s.port)
        authMethod = s.authMethod
        password = s.password
        keyPath = s.keyPath
        keyId = s.keyId
        encoding = s.encoding
        hostKeyAlgos = s.hostKeyAlgos
        ciphers = s.ciphers
        kexAlgos = s.kexAlgos
        proxyURL = s.proxyURL
        disableProxy = s.disableProxy
        timeout = String(s.timeoutMs)
        heartbeat = String(s.heartbeatMs)
        initialCommand = s.initialCommand
        defaultPath = s.defaultPath
    }

    func buildConnection() -> SSHConnection {
        SSHConnection(
            user: user.trimmingCharacters(in: .whitespaces).isEmpty ? "root" : user.trimmingCharacters(in: .whitespaces),
            host: address.trimmingCharacters(in: .whitespaces),
            port: Int(port) ?? 22,
            authMethod: authMethod,
            password: password,
            keyPath: keyPath.trimmingCharacters(in: .whitespaces),
            keyId: keyId,
            encoding: encoding,
            hostKeyAlgos: hostKeyAlgos,
            ciphers: ciphers,
            kexAlgos: kexAlgos,
            proxyURL: proxyURL.trimmingCharacters(in: .whitespaces),
            disableProxy: disableProxy,
            timeoutMs: Int(timeout) ?? 10000,
            heartbeatMs: Int(heartbeat) ?? 5000,
            initialCommand: initialCommand,
            defaultPath: defaultPath
        )
    }
}
