// swift-tools-version: 6.0
import PackageDescription
import Foundation

let cefRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("sill-chromium/.cef").path
let cef = cefRoot + "/cef"

let package = Package(
    name: "Sill",
    platforms: [.macOS("27.0")],
    targets: [
        // The MCP server agents run: it speaks to Sill's local agent socket.
        .executableTarget(
            name: "sill-mcp",
            path: "Sources/sill-mcp",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Osize"], .when(configuration: .release))]
        ),
        // Chromium (CEF) behind a WKWebView-shaped interface: CEF's C++ stays in here.
        // CEF itself is in ~/sill-chromium/.cef (headers, the wrapper library,
        // and the framework the app bundle carries).
        .target(
            name: "SillEngine",
            path: "Sources/SillEngine",
            cxxSettings: [.unsafeFlags(["-I\(cef)", "-std=c++20", "-fobjc-arc", "-fno-rtti", "-fno-exceptions",
                                        "-Wno-deprecated-declarations", "-D__STDC_CONSTANT_MACROS", "-D__STDC_FORMAT_MACROS"])],
            linkerSettings: [.unsafeFlags(["\(cefRoot)/libcef_dll_wrapper.a"]), .linkedFramework("Cocoa")]
        ),
        .executableTarget(
            name: "Sill",
            dependencies: ["SillEngine"],
            path: "Sources/Sill",
            // AppKit is main-thread by nature; strict isolation buys ceremony here.
            // Release builds use -O: speed over size in the hot loops.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
