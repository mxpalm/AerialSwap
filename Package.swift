// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AerialSwap",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "AerialSwap", path: "Sources/AerialSwap")
    ]
)
