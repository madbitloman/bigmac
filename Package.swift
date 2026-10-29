// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BigMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BigMac",
            path: "Sources/BigMac",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreServices"),
            ]
        )
    ]
)
