// swift-tools-version: 5.9
// termo vendored 副本：仅为修上游 0.12.1 的 inout 遮蔽 bug（见 TextLayoutManager+Layout.swift）。
// 已剔除开发期依赖（SwiftLintPlugin 构建插件）与测试 target，避免与根包的本地壳产生 identity 冲突。
import PackageDescription

let package = Package(
    name: "CodeEditTextView",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CodeEditTextView",
            targets: ["CodeEditTextView"]
        ),
    ],
    dependencies: [
        // Text mutation, storage helpers
        .package(url: "https://github.com/ChimeHQ/TextStory", from: "0.9.0"),
        // Useful data structures
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "CodeEditTextView",
            dependencies: [
                "TextStory",
                .product(name: "Collections", package: "swift-collections"),
                "CodeEditTextViewObjC"
            ]
        ),
        .target(
            name: "CodeEditTextViewObjC",
            publicHeadersPath: "include"
        ),
    ]
)
