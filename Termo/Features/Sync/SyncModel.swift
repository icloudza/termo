import AppKit
import Foundation
import UniformTypeIdentifiers

enum SyncUIError: LocalizedError {
    case weakMaster
    case badPayload

    var errorDescription: String? {
        switch self {
        case .weakMaster: return String(localized: "主密码至少 8 位（用于加密备份）")
        case .badPayload: return String(localized: "备份内容无法解析")
        }
    }
}

/// 同步面板的状态与操作编排：WebDAV 配置持久化（密码入 Keychain），主密码只留本次运行内存。
@MainActor
final class SyncModel: ObservableObject {
    static let shared = SyncModel()

    /// 等待用户裁决的合并结果；uploadAfter=true 表示裁决后还要把合并结果传回 WebDAV。
    struct PendingMerge {
        let result: SyncMergeResult
        let uploadAfter: Bool
    }

    @Published var baseURL: String
    @Published var username: String
    @Published var password: String
    @Published var remotePath: String
    @Published var masterPassword = ""
    @Published var busy = false
    @Published var statusText = ""
    @Published var statusIsError = false
    @Published var pendingMerge: PendingMerge? = nil
    @Published var lastSyncAt: Date? = SyncConfigStore.lastSyncAt

    private init() {
        baseURL = SyncConfigStore.baseURL
        username = SyncConfigStore.username
        password = SyncKeychain.loadPassword()
        remotePath = SyncConfigStore.remotePath
    }

    var config: WebDAVConfig {
        WebDAVConfig(baseURL: baseURL, username: username, password: password, remotePath: remotePath)
    }

    /// 持久化 WebDAV 配置（密码进 Keychain，其余进 UserDefaults）。
    func saveConfig() {
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        SyncConfigStore.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        SyncConfigStore.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        SyncConfigStore.remotePath = path.isEmpty ? SyncConfigStore.defaultRemotePath : path
        remotePath = SyncConfigStore.remotePath
        SyncKeychain.savePassword(password)
    }

    // MARK: - 操作

    func testConnection() async {
        guard validateConfig() else { return }
        saveConfig()
        await perform {
            let exists = try await WebDAVClient.test(self.config)
            return exists
                ? String(localized: "连接成功")
                : String(localized: "连接成功；远端目录尚不存在，首次同步会尝试创建（Seafile 需先在网页端新建资料库）")
        }
    }

    /// 双向合并同步：下载 → 解密 → 合并 → 应用 → 加密上传。冲突时先弹窗裁决。
    func mergeSync(model: AppModel) async {
        guard validateConfig(), validateMaster() else { return }
        saveConfig()
        await perform {
            let local = SyncEngine.makePayload(model: model)
            var remoteData: Data?
            do { remoteData = try await WebDAVClient.download(self.config) } catch WebDAVError.notFound {
                remoteData = nil
            }
            guard let remoteData else {
                guard self.masterPassword.count >= 8 else { throw SyncUIError.weakMaster }
                try await self.upload(local)
                return String(localized: "远端无备份，已用本机数据创建")
            }
            let remote = try await self.decode(remoteData)
            let result = SyncEngine.merge(local: local, remote: remote)
            guard result.conflicts.isEmpty else {
                self.pendingMerge = PendingMerge(result: result, uploadAfter: true)
                return String(localized: "发现 \(result.conflicts.count) 处冲突，请选择保留哪边")
            }
            SyncEngine.apply(result.merged, to: model)
            try await self.upload(result.merged)
            return self.summary(result)
        }
    }

    /// 仅从 WebDAV 导入：下载 → 解密 → 合并 → 应用（不回传）。
    func importFromWebDAV(model: AppModel) async {
        guard validateConfig(), validateMaster() else { return }
        saveConfig()
        await perform {
            let remoteData = try await WebDAVClient.download(self.config)
            let remote = try await self.decode(remoteData)
            let local = SyncEngine.makePayload(model: model)
            let result = SyncEngine.merge(local: local, remote: remote)
            guard result.conflicts.isEmpty else {
                self.pendingMerge = PendingMerge(result: result, uploadAfter: false)
                return String(localized: "发现 \(result.conflicts.count) 处冲突，请选择保留哪边")
            }
            SyncEngine.apply(result.merged, to: model)
            return self.summary(result)
        }
    }

    /// 以本机数据覆盖远端备份（单向上传，不做合并）。
    func uploadLocal(model: AppModel) async {
        guard validateConfig(), validateMaster() else { return }
        guard masterPassword.count >= 8 else {
            statusText = SyncUIError.weakMaster.errorDescription ?? ""
            statusIsError = true
            return
        }
        saveConfig()
        await perform {
            let payload = SyncEngine.makePayload(model: model)
            try await self.upload(payload)
            return String(localized: "已上传本机数据覆盖远端备份")
        }
    }

    /// 导出加密备份到本地文件（文件内容为密文，明文不落盘）。
    func exportToFile(model: AppModel) {
        guard validateMaster() else { return }
        guard masterPassword.count >= 8 else {
            statusText = SyncUIError.weakMaster.errorDescription ?? ""
            statusIsError = true
            return
        }
        let panel = NSSavePanel()
        panel.title = String(localized: "导出加密备份")
        panel.nameFieldStringValue = "termo-backup-\(Self.dateStamp()).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload = SyncEngine.makePayload(model: model)
        Task {
            await perform {
                let plain = try JSONEncoder().encode(payload)
                let password = self.masterPassword
                let encrypted = try await Task.detached(priority: .userInitiated) {
                    try SyncCrypto.encrypt(plain, password: password)
                }.value
                try encrypted.write(to: url, options: .atomic)
                return String(localized: "已导出加密备份：\(url.lastPathComponent)")
            }
        }
    }

    /// 从本地加密备份文件导入并合并。
    func importFromFile(model: AppModel) {
        guard validateMaster() else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择 Termo 备份文件")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await perform {
                let data = try Data(contentsOf: url)
                let remote = try await self.decode(data)
                let local = SyncEngine.makePayload(model: model)
                let result = SyncEngine.merge(local: local, remote: remote)
                guard result.conflicts.isEmpty else {
                    self.pendingMerge = PendingMerge(result: result, uploadAfter: false)
                    return String(localized: "发现 \(result.conflicts.count) 处冲突，请选择保留哪边")
                }
                SyncEngine.apply(result.merged, to: model)
                return self.summary(result)
            }
        }
    }

    /// 冲突裁决完成：生成最终负载并应用；来源为 WebDAV 的合并同步还会回传远端。
    func resolvePending(choices: [String: Bool], model: AppModel) async {
        guard let pending = pendingMerge else { return }
        pendingMerge = nil
        let payload = SyncEngine.resolve(result: pending.result, choices: choices)
        SyncEngine.apply(payload, to: model)
        guard pending.uploadAfter else {
            statusIsError = false
            statusText = String(localized: "已从备份合并导入")
            return
        }
        await perform {
            try await self.upload(payload)
            return String(localized: "同步完成")
        }
    }

    func cancelPending() {
        pendingMerge = nil
        statusIsError = false
        statusText = String(localized: "已取消本次合并")
    }

    // MARK: - 内部

    private func perform(_ action: @escaping () async throws -> String?) async {
        guard !busy else { return }
        busy = true
        statusIsError = false
        do {
            if let message = try await action() { statusText = message }
        } catch {
            statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusIsError = true
        }
        busy = false
    }

    private func upload(_ payload: SyncPayload) async throws {
        let plain = try JSONEncoder().encode(payload)
        let password = masterPassword
        let encrypted = try await Task.detached(priority: .userInitiated) {
            try SyncCrypto.encrypt(plain, password: password)
        }.value
        try await WebDAVClient.upload(config, data: encrypted)
        SyncConfigStore.lastSyncAt = Date()
        lastSyncAt = SyncConfigStore.lastSyncAt
    }

    private func decode(_ data: Data) async throws -> SyncPayload {
        let password = masterPassword
        let plain = try await Task.detached(priority: .userInitiated) {
            try SyncCrypto.decrypt(data, password: password)
        }.value
        do {
            let payload = try JSONDecoder().decode(SyncPayload.self, from: plain)
            guard payload.format == "termo-payload", payload.version <= 1 else {
                throw SyncUIError.badPayload
            }
            return payload
        } catch {
            throw SyncUIError.badPayload
        }
    }

    private func summary(_ result: SyncMergeResult) -> String {
        guard result.localOnlyCount > 0 || result.remoteOnlyCount > 0 else {
            return String(localized: "同步完成，无变更")
        }
        return String(localized: "同步完成（仅本机 \(result.localOnlyCount) 项，仅远端 \(result.remoteOnlyCount) 项）")
    }

    private func validateConfig() -> Bool {
        guard config.isComplete else {
            statusText = String(localized: "请先填写 WebDAV 服务器地址与远程路径")
            statusIsError = true
            return false
        }
        return true
    }

    private func validateMaster() -> Bool {
        guard !masterPassword.isEmpty else {
            statusText = String(localized: "请先输入主密码（用于加解密备份）")
            statusIsError = true
            return false
        }
        return true
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }
}
