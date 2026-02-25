// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "APSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "APSwitcher",
            path: "Sources/APSwitcher"
        )
    ]
)
