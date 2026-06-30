import Foundation

/// 把密钥库（钥匙串）里的私钥落成 ssh 可用的工作文件（0600，等同 ~/.ssh/id_* 的安全姿态）。
/// 幂等：文件已存在则直接复用，避免每次连接重写。删除密钥时清理对应文件。
enum KeyMaterializer {
    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo/keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }

    /// 返回该密钥 id 的工作私钥文件路径；钥匙串无此私钥则返回 nil。
    static func path(forKeyId id: String) -> String? {
        let url = dir.appendingPathComponent(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let pem = KeyKeychain.privateKey(id) else { return nil }
            do {
                try pem.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { return nil }
        }
        return url.path
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(id))
    }
}

enum KeyError: LocalizedError {
    case generate(String)
    case importFail(String)

    var errorDescription: String? {
        switch self {
        case .generate(let m): return "生成密钥失败：\(m)"
        case .importFail(let m): return "导入密钥失败：\(m)"
        }
    }
}

/// 进程内密钥生成 / 导入（OpenSSL EVP + 手写 OpenSSH 私钥格式，替代 spawn ssh-keygen）。
/// 产物为标准格式：ed25519 私钥 = OpenSSH 格式（加密走 bcrypt）；RSA 私钥 = OpenSSL PKCS#8 PEM；
/// 公钥为标准 `ssh-ed25519/ssh-rsa AAAA... comment` 行。已用系统 ssh-keygen 作 oracle 验证一致。
enum KeyTools {
    struct Generated { let publicKey: String; let privateKey: String; let fingerprint: String }
    struct Imported { let publicKey: String; let fingerprint: String; let type: SSHKeyType; let comment: String; let hasPassphrase: Bool }

    /// 生成密钥对（进程内）。passphrase 为空串即无口令。
    static func generate(type: SSHKeyType, comment: String, passphrase: String) throws -> Generated {
        var priv = [CChar](repeating: 0, count: 1 << 15)
        var pub = [CChar](repeating: 0, count: 4096)
        var fp = [CChar](repeating: 0, count: 256)
        var err = [CChar](repeating: 0, count: 256)
        let t: Int32 = type == .ed25519 ? 0 : 1
        let rc = termo_key_generate(t, comment, passphrase, &priv, Int32(priv.count),
                                    &pub, Int32(pub.count), &fp, 256, &err, 256)
        guard rc == 0 else { throw KeyError.generate(String(cString: err)) }
        return Generated(publicKey: String(cString: pub),
                         privateKey: String(cString: priv),
                         fingerprint: String(cString: fp))
    }

    /// 从私钥文件导入：派生公钥、指纹、类型、是否加密。
    /// 公钥来源优先级：同名 .pub（含注释，即便私钥加密也可读）→ 从私钥派生（OpenSSH 公钥明文 / PEM 未加密）。
    static func importInfo(privatePath: String) throws -> Imported {
        var pubLine = ""
        let siblingPub = privatePath + ".pub"
        if let s = try? String(contentsOfFile: siblingPub, encoding: .utf8) {
            pubLine = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var outPub = [CChar](repeating: 0, count: 4096)
        var cType: Int32 = 0
        var cEnc: Int32 = 0
        let rc = termo_key_pubkey_from_private(privatePath, "", &outPub, Int32(outPub.count), &cType, &cEnc)
        let encrypted = rc == 1 || cEnc != 0    // rc=1：PEM 加密无法派生；cEnc：OpenSSH 加密（公钥仍可派生）

        if pubLine.isEmpty {
            guard rc == 0 else {
                throw KeyError.importFail(rc == 1
                    ? "私钥已加密且无同名 .pub 文件，无法派生公钥；请连同 .pub 一起导入"
                    : "无法读取私钥")
            }
            pubLine = String(cString: outPub)
        }
        guard !pubLine.isEmpty else { throw KeyError.importFail("无法读取公钥") }

        var fp = [CChar](repeating: 0, count: 256)
        let fingerprint = termo_key_fingerprint(pubLine, &fp, 256) == 0 ? String(cString: fp) : ""

        let type: SSHKeyType = pubLine.hasPrefix("ssh-rsa") ? .rsa
            : (pubLine.hasPrefix("ssh-ed25519") ? .ed25519 : (cType == 1 ? .rsa : .ed25519))
        let comment = pubLine.split(separator: " ").dropFirst(2).joined(separator: " ")
        return Imported(publicKey: pubLine, fingerprint: fingerprint, type: type,
                        comment: comment, hasPassphrase: encrypted)
    }
}
