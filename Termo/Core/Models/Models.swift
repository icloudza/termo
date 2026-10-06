import SwiftUI

enum Section: Hashable {
    case hosts, files, sshKeys, rdp, snippets, settings
}

enum SettingsTab: String, CaseIterable, Hashable {
    case general = "通用"
    case terminal = "终端"
    case transfer = "传输"
    case monitor = "监控"
    case security = "安全"
    case keys = "快捷键"
    case about = "关于"

    var label: String {
        switch self {
        case .general: return String(localized: "通用")
        case .terminal: return String(localized: "终端")
        case .transfer: return String(localized: "传输")
        case .monitor: return String(localized: "监控")
        case .security: return String(localized: "安全")
        case .keys: return String(localized: "快捷键")
        case .about: return String(localized: "关于")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .terminal: return "terminal"
        case .transfer: return "arrow.up.arrow.down"
        case .monitor: return "speedometer"
        case .security: return "lock.shield"
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
struct SSHConnection: Codable, Equatable {
    // 密码不进 JSON（存 Keychain），其余字段全部持久化
    enum CodingKeys: String, CodingKey {
        case user, host, port, authMethod, keyPath, keyId, encoding, hostKeyAlgos, ciphers, kexAlgos
        case proxyURL, disableProxy, timeoutMs, heartbeatMs, initialCommand, defaultPath
    }

    var user: String = "root"
    var host: String = ""
    var port: Int = 22
    var authMethod: AuthMethod = .password
    var password: String = ""
    var keyPath: String = ""
    var keyId: String = ""   // 关联密钥库的密钥 id；非空则用库密钥（连接时落 0600 工作文件），优先于 keyPath
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

    /// 当前是否已具备自动连接所需凭证：「每次询问」需已输入本会话密码；其它方式恒为 true。
    /// 用于门控后台监控/规格探测——无凭证时跳过（UI 显示占位、不反复弹密码框），有凭证后正常采集。
    var hasUsableCredentials: Bool {
        authMethod == .ask ? !password.isEmpty : true
    }

    /// 把「终端显示编码」映射为远端 locale，开 shell 时作为 LC_ALL 环境变量发送
    /// （best-effort：依赖服务器 AcceptEnv LC_* 且有该 locale）。
    var remoteLocale: String? {
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
}

/// RDP 安全/认证级别。
enum RDPSecurity: String, Codable, CaseIterable {
    case auto, nla, tls, rdp

    var label: String {
        switch self {
        case .auto: return String(localized: "自动协商")
        case .nla:  return String(localized: "NLA（网络级认证）")
        case .tls:  return "TLS"
        case .rdp:  return String(localized: "标准 RDP")
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

/// 单个挂载点的磁盘用量（1K 块）。
struct DiskUsage: Identifiable {
    var id: String { mount }
    let mount: String
    let usedKB: Int64
    let totalKB: Int64
    var percent: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) * 100 : 0 }
}

/// 单块 GPU 的实时状态（来自 nvidia-smi；显存以 MiB 计）。
struct GPUInfo: Identifiable {
    var id: Int { index }
    let index: Int
    let name: String
    let utilPercent: Double
    let memUsedMB: Int64
    let memTotalMB: Int64
    let tempC: Int
    var memPercent: Double { memTotalMB > 0 ? Double(memUsedMB) / Double(memTotalMB) * 100 : 0 }
}

/// 一帧网速采样（字节/秒），用于网络波动折线图。
struct NetSample {
    let rx: Double
    let tx: Double
}

/// 主机实时监控的一帧采样（由 HostMonitor 流式解析 /proc 与 nvidia-smi 得到，不持久化）。
/// 速率与占用类字段需相邻两帧差值，首帧为 nil；内存以 kB（1K 块）计。
struct HostMetrics {
    var cpuPercent: Double? = nil      // 整机 CPU 占用，0–100
    var perCore: [Double] = []          // 每核 CPU 占用，0–100，按核序号排列
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var memUsedKB: Int64 = 0
    var memTotalKB: Int64 = 0
    var swapUsedKB: Int64 = 0
    var swapTotalKB: Int64 = 0
    var disks: [DiskUsage] = []
    var gpus: [GPUInfo] = []
    var netRxBytesPerSec: Double? = nil
    var netTxBytesPerSec: Double? = nil
    var uptimeSecs: Double = 0

    var memPercent: Double { memTotalKB > 0 ? Double(memUsedKB) / Double(memTotalKB) * 100 : 0 }
    var hasSwap: Bool { swapTotalKB > 0 }
    var swapPercent: Double { swapTotalKB > 0 ? Double(swapUsedKB) / Double(swapTotalKB) * 100 : 0 }
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
