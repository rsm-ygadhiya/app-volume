// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppVolumeMixer",
    platforms: [
        .macOS(.v14) // Core Audio process taps require macOS 14.4+
    ],
    targets: [
        .executableTarget(
            name: "AppVolumeMixer",
            path: "Sources/AppVolumeMixer"
        )
    ]
)
