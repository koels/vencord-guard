// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VencordGuard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "VencordGuard", path: "Sources/VencordGuard")
    ]
)
