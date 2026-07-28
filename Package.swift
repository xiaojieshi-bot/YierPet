// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YierPet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "YierPet",
            path: "Sources/YierPet",
            resources: [.copy("Resources/spritesheet.webp")]
        )
    ]
)
