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
        // 本地 vendoring 覆盖 CodeEditSymbols 0.2.3：上游 manifest 未把 Symbols.xcassets 声明为资源，
        // 纯 swift build 因此缺 Bundle.module（Xcode 能自动处理 asset catalog，故只在命令行打包时暴露）。
        // identity=codeeditsymbols 的 path 依赖取代远程版本，并补上资源声明。
        .package(path: "./LocalPackages/CodeEditSymbols"),
    ],
    targets: [
        .executableTarget(
            name: "Termo",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
            ],
            path: "Sources/Termo",
            exclude: ["Info.plist"],   // 不当源文件扫描；由下方 linker 嵌入
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/font-logos.ttf"),   // 发行版 logo 字体(OFL),运行时注册
            ],
            linkerSettings: [
                // 把 Info.plist 嵌进可执行文件的 __TEXT,__info_plist 段。SwiftPM 可执行程序没有 .app 外壳，
                // 这样 Bundle.main 才能拿到 bundle id / 版本等身份信息（影响 UserDefaults 域、Keychain、App 标识）。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    // 绝对路径：链接器的工作目录在不同构建方式/配置下不固定（release 常在 .build 内），
                    // 相对路径会 errno=2 找不到；用 Context.packageDirectory 锚定到包根。
                    "-Xlinker", "\(Context.packageDirectory)/Sources/Termo/Info.plist",
                ]),
            ]
        ),
    ]
)
