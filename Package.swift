// swift-tools-version:6.0
import Foundation
import PackageDescription

// Ad blocking is built on an engine that isn't in this repository. scripts/fetch-blocker-sources.sh sets up
// Sources/BigMac/AdBlock/Engine with it, or with a stand-in when its source isn't on this Mac (see README, Building).
if !FileManager.default.fileExists(atPath: Context.packageDirectory + "/Sources/BigMac/AdBlock/Engine/BlockerEngine.swift") {
    fatalError("\n\nRun scripts/fetch-blocker-sources.sh first: Sources/BigMac/AdBlock/Engine is missing (see README, Building).\n")
}

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
                .linkedFramework("SafariServices"),
            ]
        )
    ]
)
