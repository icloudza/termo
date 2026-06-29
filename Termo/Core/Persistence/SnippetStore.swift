import Foundation

/// 代码片段的 JSON 持久化（~/Library/Application Support/termo/snippets.json）。
/// 片段正文不含机密，整体明文落盘即可（与 KeyStore 同目录、同写法）。
enum SnippetStore {
    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var url: URL { dir.appendingPathComponent("snippets.json") }

    static func load() -> [Snippet] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Snippet].self, from: data) else { return [] }
        return items
    }

    static func save(_ snippets: [Snippet]) {
        if let data = try? JSONEncoder().encode(snippets) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
