// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Termo",
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
            name: "Termo",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
            ],
            path: "Sources/Termo",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIcon.png"),
            ]
        ),
    ]
)
