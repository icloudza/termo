import Foundation

/// WebDAV 连接配置。密码只在内存/Keychain 中流转，不写 UserDefaults。
struct WebDAVConfig: Equatable {
    var baseURL: String
    var username: String
    var password: String
    var remotePath: String  // 相对路径，如 "termo/termo-sync.json"

    var isComplete: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !remotePath.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

enum WebDAVError: LocalizedError {
    case invalidURL
    case authFailed
    case notFound
    case parentMissing
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "WebDAV 地址或远程路径无效")
        case .authFailed: return String(localized: "WebDAV 认证失败，请检查用户名与密码")
        case .notFound: return String(localized: "远端还没有备份文件")
        case .parentMissing:
            return String(localized: "远端目录不存在且无法创建：请先在服务器网页端建好第一级目录（Seafile 需先新建资料库）")
        case .serverError(let code): return String(localized: "WebDAV 服务器返回错误（HTTP \(code)）")
        }
    }
}

/// 极简 WebDAV 客户端：只用到 GET / PUT / PROPFIND / MKCOL 四个方法，Basic 认证。
enum WebDAVClient {
    /// 下载备份文件。远端不存在时抛 `.notFound`。
    static func download(_ cfg: WebDAVConfig) async throws -> Data {
        var req = URLRequest(url: try fileURL(cfg))
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        addAuth(&req, cfg)
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, allow: [200], context: "下载")
        return data
    }

    /// 上传备份文件；父目录不存在时自动逐级 MKCOL 后重试一次。
    static func upload(_ cfg: WebDAVConfig, data: Data) async throws {
        var req = URLRequest(url: try fileURL(cfg))
        req.httpMethod = "PUT"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuth(&req, cfg)
        req.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404 || code == 409 {
            try await ensureParentDirectories(cfg)
            let (_, retry) = try await URLSession.shared.data(for: req)
            try check(retry, allow: [200, 201, 204], context: "上传")
            return
        }
        try check(response, allow: [200, 201, 204], context: "上传")
    }

    /// 测试连接与认证。返回目标目录是否已存在（不存在时首次同步会尝试自动创建）。
    static func test(_ cfg: WebDAVConfig) async throws -> Bool {
        var url = try baseURL(cfg)
        for segment in pathSegments(cfg).dropLast() { url.appendPathComponent(segment) }
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.timeoutInterval = 20
        req.setValue("0", forHTTPHeaderField: "Depth")
        addAuth(&req, cfg)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.serverError(-1) }
        switch http.statusCode {
        case 200, 207: return true
        case 404: return false
        case 401, 403: throw WebDAVError.authFailed
        case 405: return true  // 服务器不支持 PROPFIND，无法判断，视为可用
        default: throw WebDAVError.serverError(http.statusCode)
        }
    }

    // MARK: - 内部

    private static func addAuth(_ req: inout URLRequest, _ cfg: WebDAVConfig) {
        let raw = "\(cfg.username):\(cfg.password)"
        let token = Data(raw.utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func check(_ response: URLResponse, allow: Set<Int>, context: String) throws {
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.serverError(-1) }
        if allow.contains(http.statusCode) { return }
        switch http.statusCode {
        case 401, 403: throw WebDAVError.authFailed
        case 404: throw WebDAVError.notFound
        default: throw WebDAVError.serverError(http.statusCode)
        }
    }

    private static func baseURL(_ cfg: WebDAVConfig) throws -> URL {
        var base = cfg.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base), url.scheme != nil, url.host != nil else {
            throw WebDAVError.invalidURL
        }
        return url
    }

    private static func pathSegments(_ cfg: WebDAVConfig) -> [String] {
        cfg.remotePath.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func fileURL(_ cfg: WebDAVConfig) throws -> URL {
        let segments = pathSegments(cfg)
        guard !segments.isEmpty else { throw WebDAVError.invalidURL }
        var url = try baseURL(cfg)
        for segment in segments { url.appendPathComponent(segment) }
        return url
    }

    /// 逐级创建远程目录；某级既不存在又创建失败（403/409，如 Seafile 根层库）时抛明确错误。
    /// MKCOL 对已存在目录返回 405，视为成功。
    private static func ensureParentDirectories(_ cfg: WebDAVConfig) async throws {
        let segments = pathSegments(cfg).dropLast()
        guard !segments.isEmpty else { return }
        var url = try baseURL(cfg)
        for segment in segments {
            url.appendPathComponent(segment)
            var req = URLRequest(url: url)
            req.httpMethod = "MKCOL"
            req.timeoutInterval = 20
            addAuth(&req, cfg)
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw WebDAVError.serverError(-1) }
            switch http.statusCode {
            case 200...299, 405: continue  // 201 新建成功；405 已存在
            case 401, 403, 409: throw WebDAVError.parentMissing
            default: throw WebDAVError.serverError(http.statusCode)
            }
        }
    }
}
