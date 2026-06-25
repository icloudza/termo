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
        // 本地 vendoring 覆盖 CodeEditTextView：修上游 0.12.1 的 inout 遮蔽 bug（行宽写不回→不换行无横滚）。
        // 同名（identity=codeedittextview）的 path 依赖覆盖 CodeEditSourceEditor 传递引入的远程版本。
        .package(path: "./LocalPackages/CodeEditTextView"),
        // 本地 vendoring CodeEditSourceEditor：为汉化 Find/Replace 面板与右键菜单的写死英文。
        // identity=codeeditsourceeditor 的 path 依赖取代远程 0.15.2。
        .package(path: "./LocalPackages/CodeEditSourceEditor"),
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
