import Foundation

/// 同步引擎：本地打包 → 双向合并 → 应用合并结果。
/// 密码 / 私钥只在 Keychain 与内存之间流转；本引擎不写任何明文文件。
@MainActor
enum SyncEngine {

    // MARK: - 打包

    /// 汇总本机全部可同步数据。密码从内存中的模型与 Keychain 读取，只存在于返回结构里。
    static func makePayload(model: AppModel) -> SyncPayload {
        var hostPasswords: [String: String] = [:]
        for host in model.hosts {
            // 「每次询问」的密码是本会话内存值，不同步（与 HostStore.saveHosts 的落盘策略一致）。
            if let ssh = host.ssh, ssh.authMethod != .ask, !ssh.password.isEmpty {
                hostPasswords[host.id] = ssh.password
            } else if let rdp = host.rdp, !rdp.password.isEmpty {
                hostPasswords[host.id] = rdp.password
            }
        }
        return SyncPayload(
            exportedAt: Date(),
            deviceName: SyncConfigStore.deviceName,
            hosts: model.hosts,
            hostPasswords: hostPasswords,
            keys: model.sshKeys,
            privateKeys: KeyKeychain.loadAll(),
            snippets: model.snippets,
            forwards: model.forwards,
            rdpCerts: RDPCertTrustStore.shared.entries,
            settings: SyncedSettings.capture())
    }

    // MARK: - 双向合并

    /// 按 id 合并本机与远端：只在一侧存在的条目直接并入；同 id 内容不同则记为冲突（默认保留本机）。
    /// 注意：不做删除同步——删除只影响本机，另一端下次合并会把条目带回来。
    static func merge(local: SyncPayload, remote: SyncPayload) -> SyncMergeResult {
        var merged = local
        merged.exportedAt = Date()
        var conflicts: [SyncConflict] = []
        var localOnly = 0
        var remoteOnly = 0

        // 主机（含密码）：按自然键「协议|IP|端口|名称」匹配，跨设备的随机 UUID 不作为身份。
        // 名称不同时回退到「协议|IP|端口」匹配（记为冲突，弹窗逐字段对比名称等差异）。
        // 匹配成功的主机沿用本机 id：端口转发等对 hostId 的引用不会失效。
        var mergedHosts: [Host] = []
        var mergedHostPasswords = local.hostPasswords
        var matchedRemoteIDs = Set<String>()
        var remoteIDToMergedID: [String: String] = [:]  // 远端主机 id → 合并后（本机）id
        for lh in local.hosts {
            let remoteHost =
                remote.hosts.first {
                    !matchedRemoteIDs.contains($0.id) && hostNaturalKey($0) == hostNaturalKey(lh)
                }
                ?? remote.hosts.first {
                    !matchedRemoteIDs.contains($0.id) && hostFallbackKey($0) == hostFallbackKey(lh)
                }
            guard let rh = remoteHost else { mergedHosts.append(lh); localOnly += 1; continue }
            matchedRemoteIDs.insert(rh.id)
            remoteIDToMergedID[rh.id] = lh.id
            let lp = local.hostPasswords[lh.id]
            let rp = remote.hostPasswords[rh.id]
            if hostEquivalent(lh, password: lp, rh, password: rp) {
                mergedHosts.append(lh)
            } else {
                conflicts.append(
                    SyncConflict(item: .host(local: lh, localPassword: lp, remote: rh, remotePassword: rp)))
                mergedHosts.append(lh)  // 默认保留本机；选远端时 resolve 换成远端内容但沿用本机 id
            }
        }
        for rh in remote.hosts where !matchedRemoteIDs.contains(rh.id) {
            mergedHosts.append(rh)
            if let pw = remote.hostPasswords[rh.id], !pw.isEmpty { mergedHostPasswords[rh.id] = pw }
            remoteOnly += 1
        }
        merged.hosts = mergedHosts
        merged.hostPasswords = mergedHostPasswords

        // 密钥（含私钥 PEM）
        let remoteKeys = Dictionary(remote.keys.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let localKeyIDs = Set(local.keys.map(\.id))
        var mergedKeys: [SSHKey] = []
        var mergedPrivateKeys = local.privateKeys
        for lk in local.keys {
            guard let rk = remoteKeys[lk.id] else { mergedKeys.append(lk); localOnly += 1; continue }
            let lp = local.privateKeys[lk.id]
            let rp = remote.privateKeys[rk.id]
            if lk == rk, lp == rp {
                mergedKeys.append(lk)
            } else {
                conflicts.append(SyncConflict(item: .key(local: lk, localPEM: lp, remote: rk, remotePEM: rp)))
                mergedKeys.append(lk)
            }
        }
        for rk in remote.keys where !localKeyIDs.contains(rk.id) {
            mergedKeys.append(rk)
            if let pem = remote.privateKeys[rk.id] { mergedPrivateKeys[rk.id] = pem }
            remoteOnly += 1
        }
        merged.keys = mergedKeys
        merged.privateKeys = mergedPrivateKeys

        // 代码片段
        let remoteSnippets = Dictionary(remote.snippets.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let localSnippetIDs = Set(local.snippets.map(\.id))
        var mergedSnippets: [Snippet] = []
        for ls in local.snippets {
            guard let rs = remoteSnippets[ls.id] else { mergedSnippets.append(ls); localOnly += 1; continue }
            if snippetEquivalent(ls, rs) {
                mergedSnippets.append(ls)
            } else {
                conflicts.append(SyncConflict(item: .snippet(local: ls, remote: rs)))
                mergedSnippets.append(ls)
            }
        }
        for rs in remote.snippets where !localSnippetIDs.contains(rs.id) {
            mergedSnippets.append(rs)
            remoteOnly += 1
        }
        merged.snippets = mergedSnippets

        // 端口转发规则；远端规则的 hostId 先经主机映射表归一（自然键匹配到的主机改用本机 id）
        let mappedRemoteForwards = remote.forwards.map { rf -> ForwardRule in
            guard let mapped = remoteIDToMergedID[rf.hostId] else { return rf }
            var copy = rf
            copy.hostId = mapped
            return copy
        }
        let remoteForwards = Dictionary(
            mappedRemoteForwards.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let localForwardIDs = Set(local.forwards.map(\.id))
        var mergedForwards: [ForwardRule] = []
        for lf in local.forwards {
            guard let rf = remoteForwards[lf.id] else { mergedForwards.append(lf); localOnly += 1; continue }
            if lf == rf {
                mergedForwards.append(lf)
            } else {
                conflicts.append(SyncConflict(item: .forward(local: lf, remote: rf)))
                mergedForwards.append(lf)
            }
        }
        for rf in mappedRemoteForwards where !localForwardIDs.contains(rf.id) {
            mergedForwards.append(rf)
            remoteOnly += 1
        }
        merged.forwards = mergedForwards

        // RDP 信任证书（指纹一致即视为相同；trustedAt 不参与判定）
        let remoteCerts = Dictionary(remote.rdpCerts.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let localCertIDs = Set(local.rdpCerts.map(\.id))
        var mergedCerts: [RDPTrustedCert] = []
        for lc in local.rdpCerts {
            guard let rc = remoteCerts[lc.id] else { mergedCerts.append(lc); localOnly += 1; continue }
            if certEquivalent(lc, rc) {
                mergedCerts.append(lc)
            } else {
                conflicts.append(SyncConflict(item: .rdpCert(local: lc, remote: rc)))
                mergedCerts.append(lc)
            }
        }
        for rc in remote.rdpCerts where !localCertIDs.contains(rc.id) {
            mergedCerts.append(rc)
            remoteOnly += 1
        }
        merged.rdpCerts = mergedCerts

        // 应用设置（整体一致即可，不做逐项合并）
        if local.settings != remote.settings {
            conflicts.append(SyncConflict(item: .settings(local: local.settings, remote: remote.settings)))
        }

        return SyncMergeResult(
            merged: merged, conflicts: conflicts,
            localOnlyCount: localOnly, remoteOnlyCount: remoteOnly)
    }

    /// 按用户裁决生成最终负载：choices[id] == true 保留本机，false 使用远端；缺省保留本机。
    static func resolve(result: SyncMergeResult, choices: [String: Bool]) -> SyncPayload {
        var payload = result.merged
        for conflict in result.conflicts where choices[conflict.id] == false {
            switch conflict.item {
            case .host(let lh, _, let rh, let rp):
                if let i = payload.hosts.firstIndex(where: { $0.id == lh.id }) {
                    payload.hosts[i] = hostAdopting(rh, id: lh.id)  // 用远端内容，但沿用本机 id
                }
                if let rp, !rp.isEmpty {
                    payload.hostPasswords[lh.id] = rp
                } else {
                    payload.hostPasswords.removeValue(forKey: lh.id)
                }
            case .key(_, _, let rk, let rp):
                if let i = payload.keys.firstIndex(where: { $0.id == rk.id }) { payload.keys[i] = rk }
                if let rp, !rp.isEmpty {
                    payload.privateKeys[rk.id] = rp
                } else {
                    payload.privateKeys.removeValue(forKey: rk.id)
                }
            case .snippet(_, let rs):
                if let i = payload.snippets.firstIndex(where: { $0.id == rs.id }) { payload.snippets[i] = rs }
            case .forward(_, let rf):
                if let i = payload.forwards.firstIndex(where: { $0.id == rf.id }) { payload.forwards[i] = rf }
            case .rdpCert(_, let rc):
                if let i = payload.rdpCerts.firstIndex(where: { $0.id == rc.id }) { payload.rdpCerts[i] = rc }
            case .settings(_, let rs):
                payload.settings = rs
            }
        }
        return payload
    }

    // MARK: - 应用到本机

    /// 把合并后的负载写回本机各存储：密码回填内存后统一经 HostStore 落 Keychain，JSON 永不含密码。
    static func apply(_ payload: SyncPayload, to model: AppModel) {
        var hosts = payload.hosts
        for i in hosts.indices {
            let password = payload.hostPasswords[hosts[i].id] ?? ""
            if hosts[i].ssh != nil {
                hosts[i].ssh?.password = password
            } else if hosts[i].rdp != nil {
                hosts[i].rdp?.password = password
            }
        }
        model.hosts = hosts
        HostStore.saveHosts(hosts)

        model.sshKeys = payload.keys
        KeyKeychain.saveAll(payload.privateKeys)
        KeyStore.save(payload.keys)

        model.snippets = payload.snippets
        SnippetStore.save(payload.snippets)

        model.forwards = payload.forwards
        HostStore.saveForwards(payload.forwards)

        RDPCertTrustStore.shared.replaceAll(payload.rdpCerts)
        payload.settings.apply()

        for host in hosts { model.checkReachability(host) }
    }

    // MARK: - 主机身份与比较

    /// 主机自然键：协议 | IP | 端口 | 名称。跨设备稳定，替代随机 UUID 作为同步身份。
    private static func hostNaturalKey(_ host: Host) -> String {
        "\(host.isRDP ? "rdp" : "ssh")|\(host.ipOrHost)|\(host.port)|\(host.name)"
    }

    /// 回退键：协议 | IP | 端口。名称不同时仍能匹配为「同一台主机」，由冲突弹窗对比名称等差异。
    private static func hostFallbackKey(_ host: Host) -> String {
        "\(host.isRDP ? "rdp" : "ssh")|\(host.ipOrHost)|\(host.port)"
    }

    /// 采用远端内容但沿用本机 id：本机转发规则等对 hostId 的引用保持有效。
    private static func hostAdopting(_ remote: Host, id: String) -> Host {
        Host(
            id: id, name: remote.name, addr: remote.addr, group: remote.group, status: remote.status,
            os: remote.os, port: remote.port, ssh: remote.ssh, notes: remote.notes,
            specs: remote.specs, latencyMs: remote.latencyMs, rdp: remote.rdp)
    }

    /// 主机配置的归一化编码：排除 id（跨设备不同）与探测结果（specs/latency），
    /// 密码由 ssh/rdp 的 CodingKeys 排除、单独比较。
    private struct HostComparable: Encodable {
        let name: String
        let addr: String
        let group: String
        let os: String
        let port: Int
        let notes: String
        let ssh: SSHConnection?
        let rdp: RDPConnection?
    }

    private static func hostEquivalent(
        _ a: Host, password pa: String?, _ b: Host, password pb: String?
    ) -> Bool {
        hostJSON(a) == hostJSON(b) && (pa ?? "") == (pb ?? "")
    }

    private static func hostJSON(_ host: Host) -> Data {
        let comparable = HostComparable(
            name: host.name, addr: host.addr, group: host.group, os: host.os,
            port: host.port, notes: host.notes, ssh: host.ssh, rdp: host.rdp)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(comparable)) ?? Data()
    }

    /// 片段比较忽略 updatedAt：内容相同就不算冲突（保留本机时间戳）。
    private static func snippetEquivalent(_ a: Snippet, _ b: Snippet) -> Bool {
        a.name == b.name && a.content == b.content && a.group == b.group
    }

    /// 证书比较只看信任内容，忽略各端写入时间。
    private static func certEquivalent(_ a: RDPTrustedCert, _ b: RDPTrustedCert) -> Bool {
        a.fingerprint == b.fingerprint && a.subject == b.subject && a.issuer == b.issuer
    }
}

// MARK: - 应用设置快照

extension SyncedSettings {
    /// 从当前设置捕获白名单快照。
    @MainActor static func capture() -> SyncedSettings {
        let s = AppSettings.shared
        var out = SyncedSettings()
        out.appearanceMode = ThemeManager.shared.mode.rawValue
        out.appLanguage = s.appLanguage.rawValue
        out.startupBehavior = s.startupBehavior.rawValue
        out.defaultShell = s.defaultShell.rawValue
        out.closeConfirm = s.closeConfirm
        out.confirmHostDelete = s.confirmHostDelete
        out.editorMinimap = s.editorMinimap
        out.termFont = s.termFont
        out.termFontSize = s.termFontSize
        out.termCursorStyle = s.termCursorStyle
        out.termCursorBlink = s.termCursorBlink
        out.termScrollback = s.termScrollback
        out.resourceAlerts = s.resourceAlerts
        out.snippetAction = s.snippetAction.rawValue
        out.rdpOpenMode = s.rdpOpenMode.rawValue
        out.rdpClipboardSync = s.rdpClipboardSync
        out.rdpWindowFullscreen = s.rdpWindowFullscreen
        return out
    }

    /// 应用到本机设置（非法枚举值回退默认，避免远端脏数据）。
    @MainActor func apply() {
        let s = AppSettings.shared
        ThemeManager.shared.mode = AppearanceMode(rawValue: appearanceMode) ?? .system
        s.appLanguage = AppLanguage(rawValue: appLanguage) ?? .zh
        s.startupBehavior = StartupBehavior(rawValue: startupBehavior) ?? .welcome
        s.defaultShell = DefaultShell(rawValue: defaultShell) ?? .auto
        s.closeConfirm = closeConfirm
        s.confirmHostDelete = confirmHostDelete
        s.editorMinimap = editorMinimap
        s.termFont = termFont
        s.termFontSize = termFontSize
        s.termCursorStyle = termCursorStyle
        s.termCursorBlink = termCursorBlink
        s.termScrollback = termScrollback
        s.resourceAlerts = resourceAlerts
        s.snippetAction = SnippetAction(rawValue: snippetAction) ?? .ask
        s.rdpOpenMode = RDPOpenMode(rawValue: rdpOpenMode) ?? .ask
        s.rdpClipboardSync = rdpClipboardSync
        s.rdpWindowFullscreen = rdpWindowFullscreen
    }
}
