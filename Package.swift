// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WordCatcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WordCatcher",
            path: "Sources/WordCatcher"
        )
    ]
)
