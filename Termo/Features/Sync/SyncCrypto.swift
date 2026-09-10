import CommonCrypto
import CryptoKit
import Foundation
import Security

enum SyncCryptoError: LocalizedError {
    case unsupportedFormat
    case wrongPasswordOrCorrupt
    case randomFailed
    case deriveFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return String(localized: "不是有效的 Termo 备份文件")
        case .wrongPasswordOrCorrupt: return String(localized: "主密码错误，或备份文件已损坏")
        case .randomFailed: return String(localized: "随机数生成失败")
        case .deriveFailed: return String(localized: "密钥派生失败")
        }
    }
}

/// 备份加密：PBKDF2-HMAC-SHA256 派生 256 位密钥 + AES-GCM 认证加密。
/// 主密码不落盘、不进 Keychain；明文负载只在内存中短暂存在。
enum SyncCrypto {
    /// PBKDF2 迭代次数（OWASP 对 SHA-256 的推荐量级）。写入信封，解密时按文件记录值执行。
    static let defaultIterations = 600_000
    private static let saltLength = 16

    /// 明文 → 加密信封 JSON（可写文件 / 上传 WebDAV）。
    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        let salt = try randomBytes(saltLength)
        let key = try deriveKey(password: password, salt: salt, iterations: defaultIterations)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw SyncCryptoError.unsupportedFormat }
        let envelope = SyncEnvelope(
            iterations: defaultIterations,
            salt: salt.base64EncodedString(),
            data: combined.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    /// 加密信封 JSON → 明文。密码错误与文件损坏都表现为 GCM 认证失败。
    static func decrypt(_ envelopeData: Data, password: String) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: envelopeData),
            envelope.isSupported,
            (1...10_000_000).contains(envelope.iterations),  // 防恶意文件用超大迭代数拖死解密
            let salt = Data(base64Encoded: envelope.salt),
            let combined = Data(base64Encoded: envelope.data)
        else {
            throw SyncCryptoError.unsupportedFormat
        }
        let key = try deriveKey(password: password, salt: salt, iterations: envelope.iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw SyncCryptoError.wrongPasswordOrCorrupt
        }
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { pwPtr in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwPtr, strlen(pwPtr),
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(max(1, iterations)),
                    &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw SyncCryptoError.deriveFailed }
        return SymmetricKey(data: Data(derived))
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw SyncCryptoError.randomFailed
        }
        return Data(bytes)
    }
}
