// swift-tools-version: 5.9
// termo vendored 副本（CodeEditSourceEditor 0.15.2）：为汉化 Find/Replace 面板与右键菜单的写死英文而引入。
// 相对上游裁剪：删 testTarget 与 swift-custom-dump（仅测试用）。
// CodeEditTextView / CodeEditSymbols 直接引同目录的本地兄弟包（../）——它们都是 termo 的 vendored 版本，
// 用 path 而非 GitHub URL 可避免「同一 identity 远程+本地两个来源」的冲突警告（将来会升级为错误）。
// SwiftLint 构建插件已剔除（仅用于 lint CodeEdit 自身代码，对 termo 编译无意义）。
import PackageDescription

let package = Package(
    name: "CodeEditSourceEditor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodeEditSourceEditor", targets: ["CodeEditSourceEditor"])
    ],
    dependencies: [
        .package(path: "../CodeEditTextView"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20"),
        .package(path: "../CodeEditSymbols"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", from: "0.8.2"),
    ],
    targets: [
        .target(
            name: "CodeEditSourceEditor",
            dependencies: [
                "CodeEditTextView",
                "CodeEditLanguages",
                "TextFormation",
                "CodeEditSymbols"
            ]
        ),
    ]
)
