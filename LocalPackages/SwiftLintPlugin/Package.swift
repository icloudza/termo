// swift-tools-version: 5.9
import PackageDescription

// 本地空壳：覆盖 CodeEdit 系列依赖传递引入的 lukepistrol/SwiftLintPlugin。
// 提供同名的 "SwiftLint" 构建插件产品，但插件不执行任何命令（不跑 SwiftLint 二进制），
// 从而绕开「Plug-in ended with uncaught signal: 5」的沙盒崩溃。SwiftLint 只是 CodeEdit
// 自身代码的 lint 工具，对 termo 编译毫无必要。
let package = Package(
    name: "SwiftLintPlugin",
    products: [
        .plugin(name: "SwiftLint", targets: ["SwiftLint"]),
    ],
    targets: [
        .plugin(
            name: "SwiftLint",
            capability: .buildTool()
        ),
    ]
)
