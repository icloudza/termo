import SwiftUI

enum Section: Hashable {
    case hosts, files, rdp, snippets, settings
}

enum SettingsTab: String, CaseIterable, Hashable {
    case general = "通用"
    case terminal = "终端"
    case keys = "快捷键"
    case about = "关于"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .keys: return "command"
        case .about: return "info.circle"
        }
    }
}

enum TabKind {
    case overview, terminal, files, editor, rdp
}

struct TabItem: Identifiable {
    let id: Int
    let kind: TabKind
    var title: String
    var hostId: String?
    var filePath: String? = nil
}

enum HostStatus: String, Codable {
    case online, offline, unknown
}

/// 一次主机会话/操作记录（终端、上传、端口转发），用于「最近会话」。
enum SessionKind: String, Codable {
    case terminal, files, upload, portForward, rdp

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .upload: return "arrow.up.circle"
        case .portForward: return "arrow.left.arrow.right"
        case .rdp: return "display"
        }
    }
}

struct SessionEvent: Codable, Identifiable {
    var id = UUID()
    let hostId: String
    let kind: SessionKind
    let detail: String
    let timestamp: Date
}

/// 一台主机的 SSH 连接配置，用于构建真实的 ssh 命令。
struct SSHConnection: Codable {
    // 密码不进 JSON（存 Keychain），其余字段全部持久化
    enum CodingKeys: String, CodingKey {
        case user, host, port, authMethod, keyPath, encoding, hostKeyAlgos, ciphers, kexAlgos
        case proxyURL, disableProxy, timeoutMs, heartbeatMs, initialCommand, defaultPath
    }

    var user: String = "root"
    var host: String = ""
    var port: Int = 22
    var authMethod: AuthMethod = .password
    var password: String = ""
    var keyPath: String = ""
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

    /// 是否需要 askpass 自动喂密钥：密码登录喂密码，密钥登录喂私钥 passphrase（密码框非空时）。
    var needsAskpass: Bool {
        !password.isEmpty && (authMethod == .password || authMethod == .key)
    }

    /// 把「终端显示编码」映射为远端 locale，经 SetEnv 转发（best-effort，依赖服务器有该 locale）。
    private var remoteLocale: String? {
        switch encoding {
        case "", "UTF-8": return encoding == "UTF-8" ? "en_US.UTF-8" : nil
        case "GBK": return "zh_CN.GBK"
        case "GB2312": return "zh_CN.GB2312"
        case "GB18030": return "zh_CN.GB18030"
        case "Big5": return "zh_TW.Big5"
        case "Shift_JIS": return "ja_JP.SJIS"
        case "EUC-JP": return "ja_JP.eucJP"
        case "EUC-KR": return "ko_KR.eucKR"
        case "KOI8-R": return "ru_RU.KOI8-R"
        case "ISO-8859-1": return "en_US.ISO8859-1"
        case "ISO-8859-15": return "en_US.ISO8859-15"
        case "Windows-1251": return "ru_RU.CP1251"
        case "Windows-1252": return "en_US.CP1252"
        case "ASCII": return "C"
        default: return nil
        }
    }

    /// 构建传给 ssh 的参数（不含 ssh 本身）。verbose 用于测试连接以解析流程。
    func sshArguments(verbose: Bool = false, multiplex: Bool = false, ephemeralKnownHosts: Bool = false) -> [String] {
        var a: [String] = []
        if verbose { a.append("-v") }
        // 连接复用：文件浏览等高频操作共享一条主连接，认证只触发一次（%C 是定长哈希，避免 socket 路径过长）
        if multiplex {
            a += ["-o", "ControlMaster=auto",
                  "-o", "ControlPath=\(NSHomeDirectory())/.termo/cm/%C",
                  "-o", "ControlPersist=120"]
        }
        // 主机密钥校验：未知主机由 App 的指纹验证弹窗预先写入 known_hosts，这里用 yes 严格校验。
        // 测试连接用临时 known_hosts（accept-new + /dev/null），不静默写入用户的 known_hosts。
        if ephemeralKnownHosts {
            a += ["-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/dev/null"]
        } else {
            a += ["-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(HostKeyVerifier.userKnownHostsArg())"]
        }
        a += ["-o", "NumberOfPasswordPrompts=1"]
        a += ["-p", String(port)]
        if timeoutMs > 0 { a += ["-o", "ConnectTimeout=\(max(1, timeoutMs / 1000))"] }
        if heartbeatMs > 0 { a += ["-o", "ServerAliveInterval=\(max(1, heartbeatMs / 1000))"] }
        // 密钥登录：指定私钥文件，只用它（不尝试 agent/默认 key）
        if authMethod == .key, !keyPath.isEmpty {
            a += ["-i", keyPath, "-o", "IdentitiesOnly=yes"]
        }
        // 终端显示编码：把对应 locale 转发给远端（依赖服务器 AcceptEnv LC_*）
        if let loc = remoteLocale { a += ["-o", "SetEnv=LC_ALL=\(loc)"] }
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
    /// 注意：返回值会被 ssh 经 /bin/sh -c 执行，必须严格校验 host/port，
    /// 否则形如 `socks5://h$(touch /tmp/x):1080` 的代理 URL 会导致本地命令注入。
    private func proxyCommand() -> String? {
        guard let comps = URLComponents(string: proxyURL),
              let scheme = comps.scheme?.lowercased(),
              let phost = comps.host, let pport = comps.port else { return nil }
        // 代理主机只允许主机名/IPv4 字符；端口必须在合法范围内。任何 shell 元字符一律拒绝。
        let hostOK = phost.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        guard hostOK, (1...65535).contains(pport) else { return nil }
        switch scheme {
        case "socks5", "socks5h": return "nc -X 5 -x \(phost):\(pport) %h %p"
        case "socks4": return "nc -X 4 -x \(phost):\(pport) %h %p"
        case "http", "https": return "nc -X connect -x \(phost):\(pport) %h %p"
        default: return nil
        }
    }
}

/// RDP 安全/认证级别。
enum RDPSecurity: String, Codable, CaseIterable {
    case auto, nla, tls, rdp

    var label: String {
        switch self {
        case .auto: return "自动协商"
        case .nla:  return "NLA（网络级认证）"
        case .tls:  return "TLS"
        case .rdp:  return "标准 RDP"
        }
    }
}

/// 一台主机的 RDP（Windows 远程桌面）连接配置。
struct RDPConnection: Codable {
    // 密码不进 JSON（存 Keychain），其余字段全部持久化
    enum CodingKeys: String, CodingKey {
        case user, host, port, domain, width, height, colorDepth, security
    }

    var user: String = "Administrator"
    var host: String = ""
    var port: Int = 3389
    var password: String = ""
    var domain: String = ""
    var width: Int = 1920
    var height: Int = 1080
    var colorDepth: Int = 32
    var security: RDPSecurity = .auto
}

/// SSH 探测得到的主机规格（真实数据，连接成功后填充）。
struct HostSpecs: Codable {
    enum CodingKeys: String, CodingKey { case os, cores, memory, disk, vram, gpu, probedAt }

    var os: String = ""
    var cores: String = ""
    var memory: String = ""
    var disk: String = ""
    var vram: String = ""   // 显存（检测到 NVIDIA 显卡时填充；空=无独显或无法检测）
    var gpu: String = ""    // 显卡型号（可选）
    var probedAt: Date? = nil   // 上次成功探测时间，用于 TTL 缓存：系统信息变化慢，无需每次打开概览都重探

    var isEmpty: Bool {
        os.isEmpty && cores.isEmpty && memory.isEmpty && disk.isEmpty && vram.isEmpty && gpu.isEmpty
    }
}

extension HostSpecs {
    // 容错解码：旧 hosts.json 缺少 vram/gpu（乃至其它）键时按空串处理，
    // 否则合成解码器会抛 keyNotFound，导致整台主机加载失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        cores = try c.decodeIfPresent(String.self, forKey: .cores) ?? ""
        memory = try c.decodeIfPresent(String.self, forKey: .memory) ?? ""
        disk = try c.decodeIfPresent(String.self, forKey: .disk) ?? ""
        vram = try c.decodeIfPresent(String.self, forKey: .vram) ?? ""
        gpu = try c.decodeIfPresent(String.self, forKey: .gpu) ?? ""
        probedAt = try c.decodeIfPresent(Date.self, forKey: .probedAt)
    }
}

struct Host: Identifiable, Codable {
    // latencyMs 是运行时探测结果，不写入 JSON
    enum CodingKeys: String, CodingKey {
        case id, name, addr, group, status, os, port, ssh, notes, specs, rdp
    }

    let id: String
    let name: String
    let addr: String
    let group: String
    var status: HostStatus
    let os: String
    var port: Int = 22
    var ssh: SSHConnection? = nil
    var notes: String = ""
    var specs: HostSpecs? = nil
    var latencyMs: Int? = nil
    // RDP（Windows 远程桌面）主机的连接配置；为 nil 表示这是一台 SSH 主机。
    // 可选字段：旧 hosts.json 无此键时按 nil 解码，不破坏既有数据。
    var rdp: RDPConnection? = nil

    /// 是否为 RDP（远程桌面）主机。
    var isRDP: Bool { rdp != nil }

    /// 仅主机名/IP（不含登录用户）。
    var ipOrHost: String {
        if let h = ssh?.host, !h.isEmpty { return h }
        if let h = rdp?.host, !h.isEmpty { return h }
        return addr.contains("@") ? String(addr.split(separator: "@").last ?? "") : addr
    }
}
