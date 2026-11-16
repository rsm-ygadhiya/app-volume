// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppVolumeMixer",
    platforms: [
        .macOS("14.4") // Core Audio process taps
    ],
    targets: [
        .executableTarget(
            name: "AppVolumeMixer",
            path: "Sources/AppVolumeMixer"
        )
    ]
)
