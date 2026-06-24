// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "termo",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
        // 成熟的原生代码编辑器内核（CodeEdit 抽出）：Tree-sitter 高亮 + 补全 UI + 查找/替换
        // + 缩略图 + 专业自动缩进/括号配对。0.x，用 exact 锁版本。
        // 注意：它经 CodeEditLanguages 传递引入 ChimeHQ/SwiftTreeSitter + 41 语言预编译 grammar，
        // 与之前手搓的 tree-sitter/* 依赖会发生 SwiftTreeSitter 包身份冲突，故那套已全部移除。
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor.git", exact: "0.15.2"),
    ],
    targets: [
        .executableTarget(
            name: "termo",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
            ],
            path: "Sources/termo",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIcon.png"),
            ]
        ),
    ]
)
