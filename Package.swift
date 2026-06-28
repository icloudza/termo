// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Termo",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
        // 本地 vendoring CodeEditSourceEditor：为汉化 Find/Replace 面板与右键菜单的写死英文（取代远程 0.15.2）。
        // 它经相对 path 直接引同目录下的 vendored CodeEditTextView / CodeEditSymbols / CodeEditLanguages，
        // 故此处不再单列后两者（避免 identity 冲突）。
        .package(path: "./LocalPackages/CodeEditSourceEditor"),
        // CodeEditTextView 由 App 直接 import（RemoteCodeEditor 用 layoutManager/textInsets），需作为直接依赖；
        // 它就是 CodeEditSourceEditor 引的那个同一本地包（同 path 同 identity，不冲突）。
        .package(path: "./LocalPackages/CodeEditTextView"),
    ],
    targets: [
        .executableTarget(
            name: "Termo",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditTextView", package: "CodeEditTextView"),
            ],
            path: "Sources/Termo",
            // Info.plist 由 linker 嵌入；Assets.xcassets 仅供 Xcode App target 用 actool 编译，
            // 纯 swift build（命令行）不处理 asset catalog，故在 SPM 目标里排除，避免「未声明资源」报错。
            exclude: ["Info.plist", "Resources/Assets.xcassets"],
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
