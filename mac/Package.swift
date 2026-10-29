// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JSTether",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "JSTether", path: "Sources/JSTether")
    ]
)
