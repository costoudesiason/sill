// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sill",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Sill",
            path: "Sources/Sill",
            // AppKit is main-thread by nature; strict isolation buys ceremony here.
            // Release builds use -O: speed over size in the hot loops.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
