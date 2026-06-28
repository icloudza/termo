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

/// 基于系统 ssh-keygen 的密钥生成 / 导入工具。产物为标准 OpenSSH 格式，兼容所有服务器。
/// 注：spawn 外部进程在 App Sandbox 下受限，当前 Developer ID/开发态可用；上架沙盒化时需另寻方案。
enum KeyTools {
    private static let keygen = "/usr/bin/ssh-keygen"

    struct Generated { let publicKey: String; let privateKey: String; let fingerprint: String }
    struct Imported { let publicKey: String; let fingerprint: String; let type: SSHKeyType; let comment: String; let hasPassphrase: Bool }

    /// 运行命令，返回 (退出码, stdout, stderr)。
    private static func run(_ args: [String]) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: keygen)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return (-1, "", "\(error.localizedDescription)") }
        let o = outPipe.fileHandleForReading.readDataToEndOfFile()
        let e = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(data: o, encoding: .utf8) ?? "",
                String(data: e, encoding: .utf8) ?? "")
    }

    /// 从指纹行解析 "SHA256:..." 与类型名（行尾括号）。形如：256 SHA256:xxxx comment (ED25519)
    private static func parseFingerprintLine(_ line: String) -> (fingerprint: String, type: SSHKeyType)? {
        let parts = line.split(separator: " ").map(String.init)
        guard let fp = parts.first(where: { $0.hasPrefix("SHA256:") }) else { return nil }
        let typeName = parts.last.flatMap { $0.hasPrefix("(") ? $0 : nil } ?? "(ED25519)"
        return (fp, SSHKeyType.from(keygenName: typeName))
    }

    /// 生成密钥对（到临时文件，读回后清理）。passphrase 为空串即无口令。
    static func generate(type: SSHKeyType, comment: String, passphrase: String) throws -> Generated {
        let priv = FileManager.default.temporaryDirectory
            .appendingPathComponent("termo-key-\(UUID().uuidString)").path
        let pub = priv + ".pub"
        defer {
            try? FileManager.default.removeItem(atPath: priv)
            try? FileManager.default.removeItem(atPath: pub)
        }
        let args = type.keygenArgs + ["-f", priv, "-N", passphrase, "-C", comment, "-q"]
        let r = run(args)
        guard r.code == 0 else { throw KeyError.generate(r.err.isEmpty ? "ssh-keygen 退出码 \(r.code)" : r.err) }

        let privPEM = (try? String(contentsOfFile: priv, encoding: .utf8)) ?? ""
        let pubLine = ((try? String(contentsOfFile: pub, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !privPEM.isEmpty, !pubLine.isEmpty else { throw KeyError.generate("读取生成结果失败") }

        let fpLine = run(["-lf", pub])
        let fp = fpLine.code == 0 ? (parseFingerprintLine(fpLine.out)?.fingerprint ?? "") : ""
        return Generated(publicKey: pubLine, privateKey: privPEM, fingerprint: fp)
    }

    /// 从私钥文件导入：派生公钥与指纹。
    /// 公钥来源优先级：同名 .pub（即便私钥加密也可读）→ `ssh-keygen -y -P ""`（未加密私钥）。
    /// 加密且无 .pub 的私钥无法在此派生公钥，报错提示。
    static func importInfo(privatePath: String) throws -> Imported {
        var pubLine = ""
        let siblingPub = privatePath + ".pub"
        if let s = try? String(contentsOfFile: siblingPub, encoding: .utf8) {
            pubLine = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 用空口令尝试派生：成功 → 未加密；失败 → 加密（hasPassphrase）。
        let derived = run(["-y", "-P", "", "-f", privatePath])
        let encrypted = derived.code != 0
        if pubLine.isEmpty {
            guard !encrypted else {
                throw KeyError.importFail("私钥已加密且无同名 .pub 文件，无法派生公钥；请连同 .pub 一起导入")
            }
            pubLine = derived.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !pubLine.isEmpty else { throw KeyError.importFail("无法读取公钥") }

        // 指纹与类型：把公钥写临时文件用 -lf 求取。
        var fingerprint = ""
        var type: SSHKeyType = .ed25519
        let tmpPub = FileManager.default.temporaryDirectory
            .appendingPathComponent("termo-imp-\(UUID().uuidString).pub")
        defer { try? FileManager.default.removeItem(at: tmpPub) }
        if (try? pubLine.write(to: tmpPub, atomically: true, encoding: .utf8)) != nil {
            let fpLine = run(["-lf", tmpPub.path])
            if fpLine.code == 0, let parsed = parseFingerprintLine(fpLine.out) {
                fingerprint = parsed.fingerprint
                type = parsed.type
            }
        }
        // 公钥行尾注释作为 comment。
        let comment = pubLine.split(separator: " ").dropFirst(2).joined(separator: " ")
        return Imported(publicKey: pubLine, fingerprint: fingerprint, type: type,
                        comment: comment, hasPassphrase: encrypted)
    }
}
