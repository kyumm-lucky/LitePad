// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LitePad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LitePad",
            path: "Sources/LitePad"
        )
    ]
)
