import PackagePlugin

/// 空操作构建插件：不返回任何构建命令，故不会执行 SwiftLint 二进制。
@main
struct SwiftLintNoop: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] { [] }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension SwiftLintNoop: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] { [] }
}
#endif
