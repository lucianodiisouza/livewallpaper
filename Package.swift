// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "LiveWallpaper",
            path: "Sources/LiveWallpaper"
        )
    ]
)
