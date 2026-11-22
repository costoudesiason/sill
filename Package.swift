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
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Osize"], .when(configuration: .release))]
        )
    ]
)
