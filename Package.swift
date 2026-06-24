// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "termo",
    // 默认本地化为简体中文：让 AppKit 提供的系统菜单/右键菜单/对话框等也显示中文，
    // 与 App 自身的中文界面一致（否则在中文系统上这些会回退成英文）。
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
        // 本地空壳覆盖 CodeEdit 传递依赖的 SwiftLintPlugin，绕过其构建插件在沙盒中崩溃
        // （Plug-in ended with uncaught signal: 5）。根 path 依赖会覆盖同名远程依赖。
        .package(path: "./LocalPackages/SwiftLintPlugin"),
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
