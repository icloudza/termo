import Foundation

/// 密钥类型。Ed25519 为默认推荐（短、快、安全）；RSA 4096 兼容老服务器。
enum SSHKeyType: String, Codable, CaseIterable, Hashable {
    case ed25519
    case rsa

    var label: String { self == .ed25519 ? "Ed25519" : "RSA 4096" }
}

/// 一把受管 SSH 密钥的元数据。私钥本体不入 JSON（存系统钥匙串，见 KeyKeychain）。
struct SSHKey: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var type: SSHKeyType
    var publicKey: String       // 完整公钥行：ssh-ed25519 AAAA... comment
    var fingerprint: String     // SHA256:...
    var comment: String
    var hasPassphrase: Bool
    let createdAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         type: SSHKeyType,
         publicKey: String,
         fingerprint: String,
         comment: String = "",
         hasPassphrase: Bool = false,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.type = type
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.comment = comment
        self.hasPassphrase = hasPassphrase
        self.createdAt = createdAt
    }
}
