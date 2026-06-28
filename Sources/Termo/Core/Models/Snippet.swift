import Foundation

/// 一段可复用的命令/脚本片段。正文支持多行与 {{变量}} 占位符（运行时填值）。
/// 全局可用，不绑定具体主机；运行时发送到当前活动终端。
struct Snippet: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var content: String        // 命令正文，支持多行
    var group: String          // 所属分组（与主机/ RDP 分组一致；空视作「未分组」）
    let createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         content: String,
         group: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.group = group
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 兼容解码：旧版 snippets.json 可能没有 group（曾用 tags），缺字段时回退默认，避免整表读取失败。
    enum CodingKeys: String, CodingKey { case id, name, content, group, createdAt, updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        content = try c.decode(String.self, forKey: .content)
        group = (try? c.decode(String.self, forKey: .group)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    /// 正文首行预览（用于侧栏行的副标题）。
    var preview: String {
        content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// 显示用分组名（空 → 未分组）。
    var displayGroup: String { group.trimmingCharacters(in: .whitespaces).isEmpty ? "未分组" : group }
}

extension Snippet {
    /// 占位符正则：{{ 变量名 }}，变量名取花括号内去空白后的文本。
    private static let varRegex = try? NSRegularExpression(pattern: "\\{\\{\\s*([^{}]+?)\\s*\\}\\}")

    /// 正文中出现的全部变量名（按出现顺序去重）。
    static func variableNames(in content: String) -> [String] {
        guard let re = varRegex else { return [] }
        let ns = content as NSString
        var seen = Set<String>(), out: [String] = []
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            if !name.isEmpty && seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// 用 values 把正文里的 {{变量}} 替换为对应值（未提供的占位符保持原样）。
    /// 从后往前替换，避免替换造成的位移影响后续匹配区间。
    static func substitute(_ content: String, values: [String: String]) -> String {
        guard let re = varRegex else { return content }
        let ns = content as NSString
        let result = NSMutableString(string: content)
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1))
            if let v = values[name] { result.replaceCharacters(in: m.range, with: v) }
        }
        return result as String
    }
}

/// 一次「带变量的片段运行/插入」请求：等待用户填值后再替换并发送到终端。
struct SnippetRunRequest: Identifiable {
    let id = UUID()
    let snippet: Snippet
    let variables: [String]    // 待填变量名（有序、去重）
    let run: Bool              // true=运行（末尾补换行直接执行）；false=插入（仅打到提示符）
}
