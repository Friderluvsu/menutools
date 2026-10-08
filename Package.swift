// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MenuTools",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MenuTools", targets: ["MenuTools"]),
        .executable(name: "menutools-smc-helper", targets: ["MenuToolsSMCHelper"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MenuTools",
            dependencies: [],
            path: "Sources/MenuTools"
        ),
        .executableTarget(
            name: "MenuToolsSMCHelper",
            dependencies: [],
            path: "Sources/MenuToolsSMCHelper"
        )
    ]
)
