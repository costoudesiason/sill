// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sill",
    platforms: [.macOS("27.0")],
    targets: [
        // The MCP server agents run: it speaks to Sill's local agent socket.
        .executableTarget(
            name: "sill-mcp",
            path: "Sources/sill-mcp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Sill",
            path: "Sources/Sill",
            // AppKit is main-thread by nature; strict isolation buys ceremony here.
            // Release builds use -O: speed over size in the hot loops.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
