// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ikit", targets: ["iKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/herrkaefer/SwiftEdgeTTS.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "iKit",
            dependencies: [
                .product(name: "SwiftEdgeTTS", package: "SwiftEdgeTTS"),
            ],
            path: "Sources/iKit"
        )
    ]
)
