// swift-tools-version: 5.5

import PackageDescription

// 本地 vendoring：上游 CodeEditSymbols 0.2.3 的 manifest 未把 Symbols.xcassets 声明为资源，
// 在 Xcode 里能自动处理 asset catalog，但纯 swift build 不会，导致缺少 Bundle.module。
// 这里显式声明该资源（并去掉仅测试用的 SnapshotTesting 依赖），使 swift build 也能正常打包。
let package = Package(
    name: "CodeEditSymbols",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "CodeEditSymbols",
            targets: ["CodeEditSymbols"]),
    ],
    targets: [
        .target(
            name: "CodeEditSymbols",
            resources: [.process("Symbols.xcassets")]
        ),
    ]
)
