// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuTools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MenuTools", targets: ["MenuTools"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MenuTools",
            dependencies: [],
            path: "Sources/MenuTools"
        )
    ]
)
