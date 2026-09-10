import Foundation

/// 加密备份信封：上传到 WebDAV / 导出到本地文件的最终格式。
/// 明文负载（SyncPayload）只在加密前的内存里存在，任何路径都不落盘。
struct SyncEnvelope: Codable {
    var format: String = "termo-backup"
    var version: Int = 1
    var kdf: String = "PBKDF2-HMAC-SHA256"
    var iterations: Int
    var salt: String  // base64(16 字节随机盐)
    var cipher: String = "AES-GCM"
    var data: String  // base64(AES-GCM combined：nonce + 密文 + tag)

    var isSupported: Bool { format == "termo-backup" && version == 1 && cipher == "AES-GCM" }
}

/// 备份明文负载（仅在内存中组装与解析）。
/// 密码 / 私钥从 Keychain 读入内存后放进本结构，加密后即刻释放；绝不写明文文件。
struct SyncPayload: Codable {
    var format = "termo-payload"
    var version = 1
    var exportedAt: Date
    var deviceName: String
    /// 主机配置。Host 的 Codable 已排除密码字段，密码单独放 hostPasswords。
    var hosts: [Host]
    /// hostId → 密码（含 RDP）。
    var hostPasswords: [String: String]
    /// 密钥元数据。私钥 PEM 单独放 privateKeys。
    var keys: [SSHKey]
    /// keyId → 私钥 PEM。
    var privateKeys: [String: String]
    var snippets: [Snippet]
    var forwards: [ForwardRule]
    var rdpCerts: [RDPTrustedCert]
    var settings: SyncedSettings
}

/// 参与同步的应用设置白名单（刻意排除下载目录、并发数等与设备强相关的项）。
/// 全部字段带默认值解码：远端来自旧/新版本时缺键不导致整份备份解析失败。
struct SyncedSettings: Codable, Equatable {
    var appearanceMode: String = "跟随系统"
    var appLanguage: String = "zh"
    var startupBehavior: String = "welcome"
    var defaultShell: String = "auto"
    var closeConfirm: Bool = true
    var confirmHostDelete: Bool = true
    var editorMinimap: Bool = true
    var termFont: String = ""
    var termFontSize: Int = 13
    var termCursorStyle: String = "bar"
    var termCursorBlink: Bool = true
    var termScrollback: Int = 1000
    var resourceAlerts: Bool = true
    var snippetAction: String = "ask"
    var rdpOpenMode: String = "ask"
    var rdpClipboardSync: Bool = true
    var rdpWindowFullscreen: Bool = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case appearanceMode, appLanguage, startupBehavior, defaultShell, closeConfirm, confirmHostDelete
        case editorMinimap, termFont, termFontSize, termCursorStyle, termCursorBlink, termScrollback
        case resourceAlerts, snippetAction, rdpOpenMode, rdpClipboardSync, rdpWindowFullscreen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearanceMode = try c.decodeIfPresent(String.self, forKey: .appearanceMode) ?? "跟随系统"
        appLanguage = try c.decodeIfPresent(String.self, forKey: .appLanguage) ?? "zh"
        startupBehavior = try c.decodeIfPresent(String.self, forKey: .startupBehavior) ?? "welcome"
        defaultShell = try c.decodeIfPresent(String.self, forKey: .defaultShell) ?? "auto"
        closeConfirm = try c.decodeIfPresent(Bool.self, forKey: .closeConfirm) ?? true
        confirmHostDelete = try c.decodeIfPresent(Bool.self, forKey: .confirmHostDelete) ?? true
        editorMinimap = try c.decodeIfPresent(Bool.self, forKey: .editorMinimap) ?? true
        termFont = try c.decodeIfPresent(String.self, forKey: .termFont) ?? ""
        termFontSize = try c.decodeIfPresent(Int.self, forKey: .termFontSize) ?? 13
        termCursorStyle = try c.decodeIfPresent(String.self, forKey: .termCursorStyle) ?? "bar"
        termCursorBlink = try c.decodeIfPresent(Bool.self, forKey: .termCursorBlink) ?? true
        termScrollback = try c.decodeIfPresent(Int.self, forKey: .termScrollback) ?? 1000
        resourceAlerts = try c.decodeIfPresent(Bool.self, forKey: .resourceAlerts) ?? true
        snippetAction = try c.decodeIfPresent(String.self, forKey: .snippetAction) ?? "ask"
        rdpOpenMode = try c.decodeIfPresent(String.self, forKey: .rdpOpenMode) ?? "ask"
        rdpClipboardSync = try c.decodeIfPresent(Bool.self, forKey: .rdpClipboardSync) ?? true
        rdpWindowFullscreen = try c.decodeIfPresent(Bool.self, forKey: .rdpWindowFullscreen) ?? false
    }
}

/// 一条双向合并冲突：同一 id 在本机与远端内容不同，由用户选择保留哪边。
struct SyncConflict: Identifiable {
    /// 一行字段对比：本机值 vs 远端值。值不同即高亮，供用户逐项核对。
    struct Field {
        let label: String
        let local: String
        let remote: String
        let isDifferent: Bool

        init(label: String, local: String, remote: String, different: Bool? = nil) {
            self.label = label
            self.local = local
            self.remote = remote
            self.isDifferent = different ?? (local != remote)
        }
    }

    enum Item {
        case host(local: Host, localPassword: String?, remote: Host, remotePassword: String?)
        case key(local: SSHKey, localPEM: String?, remote: SSHKey, remotePEM: String?)
        case snippet(local: Snippet, remote: Snippet)
        case forward(local: ForwardRule, remote: ForwardRule)
        case rdpCert(local: RDPTrustedCert, remote: RDPTrustedCert)
        case settings(local: SyncedSettings, remote: SyncedSettings)
    }

    let item: Item

    var id: String {
        switch item {
        case .host(let l, _, _, _): return "host-\(l.id)"
        case .key(let l, _, _, _): return "key-\(l.id)"
        case .snippet(let l, _): return "snippet-\(l.id)"
        case .forward(let l, _): return "forward-\(l.id.uuidString)"
        case .rdpCert(let l, _): return "cert-\(l.id)"
        case .settings: return "settings"
        }
    }

    var title: String {
        switch item {
        case .host(let l, _, _, _): return String(localized: "主机「\(l.name)」")
        case .key(let l, _, _, _): return String(localized: "密钥「\(l.name)」")
        case .snippet(let l, _): return String(localized: "片段「\(l.name)」")
        case .forward(let l, _): return String(localized: "转发规则「\(l.name.isEmpty ? l.summary : l.name)」")
        case .rdpCert(let l, _): return String(localized: "RDP 证书「\(l.host):\(l.port)」")
        case .settings: return String(localized: "应用设置")
        }
    }

    /// 字段级对比。主机按协议 / IP / 端口 / 名称匹配后，这里逐项列出差异供用户裁决。
    var fields: [Field] {
        switch item {
        case .host(let l, let lp, let r, let rp):
            let pwDiff = secretDifferent(lp, rp)
            let pwInconsistent = pwDiff && lp?.isEmpty == false && rp?.isEmpty == false
            return [
                Field(label: String(localized: "名称"), local: l.name, remote: r.name),
                Field(
                    label: String(localized: "协议"),
                    local: l.isRDP ? "RDP" : "SSH", remote: r.isRDP ? "RDP" : "SSH"),
                Field(label: String(localized: "地址"), local: l.ipOrHost, remote: r.ipOrHost),
                Field(label: String(localized: "端口"), local: "\(l.port)", remote: "\(r.port)"),
                Field(
                    label: String(localized: "用户名"),
                    local: l.ssh?.user ?? l.rdp?.user ?? "", remote: r.ssh?.user ?? r.rdp?.user ?? ""),
                Field(
                    label: String(localized: "分组"),
                    local: groupLabel(l.group), remote: groupLabel(r.group)),
                Field(label: String(localized: "备注"), local: l.notes, remote: r.notes),
                Field(
                    label: String(localized: "密码"),
                    local: secretLabel(lp, inconsistent: pwInconsistent),
                    remote: secretLabel(rp, inconsistent: pwInconsistent),
                    different: pwDiff),
            ]
        case .key(let l, let lp, let r, let rp):
            let pemDiff = secretDifferent(lp, rp)
            let pemInconsistent = pemDiff && lp?.isEmpty == false && rp?.isEmpty == false
            return [
                Field(label: String(localized: "名称"), local: l.name, remote: r.name),
                Field(label: String(localized: "类型"), local: l.type.label, remote: r.type.label),
                Field(label: String(localized: "指纹"), local: l.fingerprint, remote: r.fingerprint),
                Field(label: String(localized: "备注"), local: l.comment, remote: r.comment),
                Field(
                    label: String(localized: "私钥"),
                    local: secretLabel(lp, inconsistent: pemInconsistent),
                    remote: secretLabel(rp, inconsistent: pemInconsistent),
                    different: pemDiff),
            ]
        case .snippet(let l, let r):
            return [
                Field(label: String(localized: "名称"), local: l.name, remote: r.name),
                Field(
                    label: String(localized: "分组"), local: groupLabel(l.group), remote: groupLabel(r.group)),
                Field(label: String(localized: "内容"), local: l.preview, remote: r.preview),
                Field(
                    label: String(localized: "更新时间"),
                    local: Self.dateLabel(l.updatedAt), remote: Self.dateLabel(r.updatedAt)),
            ]
        case .forward(let l, let r):
            return [
                Field(
                    label: String(localized: "名称"),
                    local: l.name.isEmpty ? l.summary : l.name, remote: r.name.isEmpty ? r.summary : r.name),
                Field(label: String(localized: "类型"), local: l.kind.title, remote: r.kind.title),
                Field(
                    label: String(localized: "监听"), local: "\(l.bindAddress):\(l.listenPort)",
                    remote: "\(r.bindAddress):\(r.listenPort)"),
                Field(
                    label: String(localized: "目标"),
                    local: l.kind == .dynamic ? "—" : "\(l.destHost):\(l.destPort)",
                    remote: r.kind == .dynamic ? "—" : "\(r.destHost):\(r.destPort)"),
            ]
        case .rdpCert(let l, let r):
            return [
                Field(label: String(localized: "指纹"), local: l.fingerprint, remote: r.fingerprint),
                Field(label: String(localized: "主题"), local: l.subject ?? "—", remote: r.subject ?? "—"),
                Field(label: String(localized: "签发者"), local: l.issuer ?? "—", remote: r.issuer ?? "—"),
            ]
        case .settings(let l, let r):
            return settingsFields(l, r)
        }
    }

    // MARK: - 对比辅助

    private static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func groupLabel(_ group: String) -> String {
        group.isEmpty ? String(localized: "未分组") : group
    }

    private func secretLabel(_ value: String?, inconsistent: Bool = false) -> String {
        guard value?.isEmpty == false else { return String(localized: "无") }
        return inconsistent ? String(localized: "已保存（不一致）") : String(localized: "已保存")
    }

    /// 只比较机密是否一致，不在界面上暴露明文。
    private func secretDifferent(_ a: String?, _ b: String?) -> Bool {
        (a ?? "") != (b ?? "")
    }

    /// 设置冲突只列出不同的项，避免整块设置刷屏。
    private func settingsFields(_ l: SyncedSettings, _ r: SyncedSettings) -> [Field] {
        func onOff(_ v: Bool) -> String { v ? String(localized: "开") : String(localized: "关") }
        var out: [Field] = []
        func add(_ label: String, _ lv: String, _ rv: String) {
            if lv != rv { out.append(Field(label: label, local: lv, remote: rv)) }
        }
        add(String(localized: "外观"), l.appearanceMode, r.appearanceMode)
        add(String(localized: "语言"), l.appLanguage, r.appLanguage)
        add(String(localized: "启动行为"), l.startupBehavior, r.startupBehavior)
        add(String(localized: "默认 Shell"), l.defaultShell, r.defaultShell)
        add(String(localized: "关闭确认"), onOff(l.closeConfirm), onOff(r.closeConfirm))
        add(String(localized: "删除确认"), onOff(l.confirmHostDelete), onOff(r.confirmHostDelete))
        add(String(localized: "编辑器缩略图"), onOff(l.editorMinimap), onOff(r.editorMinimap))
        add(String(localized: "终端字体"), l.termFont, r.termFont)
        add(String(localized: "终端字号"), "\(l.termFontSize)", "\(r.termFontSize)")
        add(String(localized: "光标样式"), l.termCursorStyle, r.termCursorStyle)
        add(String(localized: "光标闪烁"), onOff(l.termCursorBlink), onOff(r.termCursorBlink))
        add(String(localized: "滚动缓冲"), "\(l.termScrollback)", "\(r.termScrollback)")
        add(String(localized: "资源告警"), onOff(l.resourceAlerts), onOff(r.resourceAlerts))
        add(String(localized: "片段运行方式"), l.snippetAction, r.snippetAction)
        add(String(localized: "RDP 打开方式"), l.rdpOpenMode, r.rdpOpenMode)
        add(String(localized: "RDP 剪贴板同步"), onOff(l.rdpClipboardSync), onOff(r.rdpClipboardSync))
        add(String(localized: "RDP 新窗口全屏"), onOff(l.rdpWindowFullscreen), onOff(r.rdpWindowFullscreen))
        if out.isEmpty { out.append(Field(label: String(localized: "设置"), local: "—", remote: "—")) }
        return out
    }
}

/// 双向合并结果：默认以本机为准的合并负载 + 待用户裁决的冲突列表。
struct SyncMergeResult {
    var merged: SyncPayload
    var conflicts: [SyncConflict]
    var localOnlyCount: Int
    var remoteOnlyCount: Int
}
