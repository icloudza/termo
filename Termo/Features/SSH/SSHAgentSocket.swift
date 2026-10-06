import SwiftUI

/// 常见 SSH Agent 的套接字位置：本机装了才在设置里给出一键填入。
enum SSHAgentPreset: CaseIterable, Identifiable {
    case onePassword, secretive

    var id: Self { self }

    var name: String {
        switch self {
        case .onePassword: return "1Password"
        case .secretive: return "Secretive"
        }
    }

    /// 以 ~ 开头保存，换用户目录也能用；连接时再展开。
    var path: String {
        switch self {
        case .onePassword: return "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        case .secretive: return "~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
        }
    }

    var isInstalled: Bool { SSHAgentSocket.exists(path) }
}

enum SSHAgentSocket {
    /// 系统 ssh-agent 的套接字。图形界面启动的 App 也能拿到（由 launchd 注入），不依赖 shell 配置。
    static var systemDefault: String {
        ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
    }

    static func exists(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces)
        return !p.isEmpty && FileManager.default.fileExists(atPath: (p as NSString).expandingTildeInPath)
    }

    /// Unix 套接字路径上限 104 字节（含结尾 0），超出会被截断、连接失败。
    static func isTooLong(_ path: String) -> Bool {
        (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath.utf8.count >= 104
    }
}

/// Agent 套接字输入框 + 已安装 Agent 的一键填入 + 套接字是否存在的提示。
/// `fallback`：留空时实际会用的路径（主机表单里是全局设置）；nil 表示留空即用系统默认。
struct AgentSocketField: View {
    @Binding var path: String
    let placeholder: String
    var fallback: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ThemedTextField(verbatim: placeholder, text: $path)
            let presets = SSHAgentPreset.allCases.filter(\.isInstalled)
            if !presets.isEmpty {
                HStack(spacing: 8) {
                    ForEach(presets) { p in
                        TintedButton(title: "使用 \(p.name)") { path = p.path }
                    }
                    if !path.isEmpty {
                        TintedButton(title: "恢复默认", tint: Pal.subtext) { path = "" }
                    }
                }
            }
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, SSHAgentSocket.isTooLong(trimmed) {
            statusLine(ok: false, okText: "",
                       badText: String(localized: "路径过长（超过 103 字节），连接会失败；可建一个较短的符号链接，如 ~/.ssh/agent.sock"))
        } else if !trimmed.isEmpty {
            statusLine(ok: SSHAgentSocket.exists(trimmed),
                       okText: String(localized: "已找到该套接字"),
                       badText: String(localized: "找不到该套接字：Agent 未启动或路径有误"))
        } else if let fallback, !fallback.trimmingCharacters(in: .whitespaces).isEmpty {
            statusLine(ok: SSHAgentSocket.exists(fallback),
                       okText: String(localized: "使用「设置 › 安全」中的 Agent：\(fallback)"),
                       badText: String(localized: "「设置 › 安全」中的 Agent 套接字不存在：\(fallback)"))
        } else {
            let sys = SSHAgentSocket.systemDefault
            statusLine(ok: SSHAgentSocket.exists(sys),
                       okText: String(localized: "使用系统 SSH Agent：\(sys)"),
                       badText: String(localized: "未检测到系统 SSH Agent（SSH_AUTH_SOCK 未设置）"))
        }
    }

    private func statusLine(ok: Bool, okText: String, badText: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(ok ? Pal.green : Pal.yellow)
            Text(ok ? okText : badText)
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
