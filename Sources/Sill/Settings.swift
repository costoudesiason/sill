import AppKit

/// Facts the settings (PaletteSettings.swift) show and act on.
enum SettingsSupport {
    static var isDefaultBrowser: Bool {
        guard let http = URL(string: "http://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: http) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// The MCP server agents run, inside the app (AGENTS.md).
    static var mcpHelper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sill-mcp").path
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
