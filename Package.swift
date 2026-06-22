// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "termo",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
    ],
    targets: [
        .executableTarget(
            name: "termo",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/termo"
        ),
    ]
)
