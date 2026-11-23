import AppKit
import SwiftUI
import WebKit

/// Settings in one translucent window, laid out the way Alcove and System
/// Settings do it: a sidebar of panes with coloured tiles on the left, the
/// chosen pane on the right as rounded groups of rows. Everything applies as
/// you change it.
@MainActor
enum SettingsWindow {
    static let size = NSSize(width: 780, height: 600)

    static func make() -> NSWindowController {
        let host = NSHostingController(rootView: SettingsView())
        host.sizingOptions = []
        host.sceneBridgingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // See-through: the desktop shows through the window's glass.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        return NSWindowController(window: window)
    }
}

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, tabs, video, memory, passwords, privacy, agents, importing, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .tabs: "Tabs"
        case .video: "Video"
        case .memory: "Memory"
        case .passwords: "Passwords"
        case .privacy: "Privacy"
        case .agents: "Agents"
        case .importing: "Import"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.pointed.fill"
        case .tabs: "square.on.square.fill"
        case .video: "play.fill"
        case .memory: "memorychip.fill"
        case .passwords: "key.fill"
        case .privacy: "hand.raised.fill"
        case .agents: "sparkles"
        case .importing: "square.and.arrow.down.fill"
        case .about: "info"
        }
    }

    var colors: [Color] {
        switch self {
        case .general, .about: [Color(white: 0.62), Color(white: 0.45)]
        case .appearance: [Color(red: 0.25, green: 0.65, blue: 1), Color(red: 0.1, green: 0.45, blue: 0.95)]
        case .tabs: [Color(red: 0.55, green: 0.5, blue: 1), Color(red: 0.4, green: 0.35, blue: 0.95)]
        case .video: [Color(red: 1, green: 0.4, blue: 0.4), Color(red: 0.92, green: 0.2, blue: 0.3)]
        case .memory: [Color(red: 0.35, green: 0.85, blue: 0.5), Color(red: 0.15, green: 0.7, blue: 0.35)]
        case .passwords: [Color(white: 0.6), Color(white: 0.42)]
        case .privacy: [Color(red: 0.3, green: 0.7, blue: 1), Color(red: 0.12, green: 0.5, blue: 0.95)]
        case .agents: [Color(red: 0.8, green: 0.45, blue: 1), Color(red: 0.6, green: 0.25, blue: 0.95)]
        case .importing: [Color(red: 1, green: 0.7, blue: 0.3), Color(red: 1, green: 0.5, blue: 0.15)]
        }
    }

    static let sections: [(String?, [SettingsPane])] = [
        (nil, [.general]),
        ("Browsing", [.appearance, .tabs, .video, .memory]),
        ("Privacy & Security", [.passwords, .privacy, .agents]),
        ("Sill", [.importing, .about]),
    ]
}

/// A pane's tile: a white symbol on a rounded square of its colour.
private struct Tile: View {
    let pane: SettingsPane
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: pane.colors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}

// MARK: - The window's content

private struct SettingsView: View {
    @AppStorage("settingsPane") private var selection: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Tile(pane: selection, size: 30)
                        Text(selection.title).font(.system(size: 20, weight: .semibold))
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 20)
                    detail
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .background(WindowGlass().ignoresSafeArea())
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Spacer().frame(height: 52)   // the traffic lights
                ForEach(Array(SettingsPane.sections.enumerated()), id: \.offset) { _, section in
                    if let title = section.0 {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 10)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                    }
                    ForEach(section.1) { pane in
                        SidebarRow(pane: pane, selected: selection == pane) { selection = pane }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .tabs: TabsPane()
        case .video: VideoPane()
        case .memory: MemoryPane()
        case .passwords: PasswordsPane()
        case .privacy: PrivacyPane()
        case .agents: AgentsPane()
        case .importing: ImportPane()
        case .about: AboutPane()
        }
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Tile(pane: pane)
                Text(pane.title).font(.system(size: 14.5))
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : hovering ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The window's ground: the desktop behind, blurred by the window server.
private struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Building blocks

/// A heading, rounded box of rows, and a note under it.
private struct Group<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 22)
    }
}

/// One row: its name on the left, its control on the right.
private struct Row<Trailing: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 14))
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}

/// The line between two rows of a group, edge to edge.
private struct Line: View {
    var body: some View { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
}

private struct SwitchRow: View {
    let label: String
    var detail: String?
    @Binding var isOn: Bool
    var body: some View {
        Row(label: label, detail: detail) { Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden() }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var isDefault = SettingsSupport.isDefaultBrowser

    var body: some View {
        Group(title: "Search") {
            Row(label: "Search engine") {
                Picker("", selection: $prefs.engine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Line()
            SwitchRow(label: "Suggest searches as you type", isOn: $prefs.suggestions)
        }
        Group(title: "Startup") {
            SwitchRow(label: "Reopen tabs from last time", isOn: $prefs.restoresTabs)
        }
        Group(title: "Default Browser") {
            Row(label: isDefault ? "Sill is your default browser" : "Open links from other apps in Sill") {
                Button("Make Default") {
                    AppDelegate.shared.makeDefaultBrowser(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isDefault = SettingsSupport.isDefaultBrowser }
                }
                .disabled(isDefault)
            }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Group(title: "Theme") {
            Row(label: "Appearance") {
                Picker("", selection: $prefs.theme) {
                    ForEach(Theme.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        Group(title: "Bar", footer: "The bar lets your desktop show through, as Finder’s sidebar does. Clear lets more through; tinted calms it toward the window’s colour.") {
            SwitchRow(label: "See the desktop through the bar", isOn: $prefs.glassBar)
            if prefs.glassBar {
                Line()
                Row(label: "Glass") {
                    HStack(spacing: 8) {
                        Text("Clear").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $prefs.glassWash, in: 0...0.9).frame(width: 180)
                        Text("Tinted").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        Group(title: "Window", footer: "Rounder corners make the window see-through, which costs some smoothness while pages scroll. Off is fastest.") {
            SwitchRow(label: "Rounder corners", isOn: $prefs.roundCorners)
            if prefs.roundCorners {
                Line()
                Row(label: "Roundness") {
                    HStack(spacing: 10) {
                        Slider(value: $prefs.cornerRadius, in: 14...36, step: 1).frame(width: 180)
                        Text("\(Int(prefs.cornerRadius)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Tabs

private struct TabsPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Group(title: "Tab Bar") {
            Row(label: "Tab width") {
                Picker("", selection: $prefs.tabWidth) {
                    ForEach(TabWidth.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Line()
            Row(label: "Close buttons") {
                Picker("", selection: $prefs.closeButtons) {
                    ForEach(CloseButtons.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            Line()
            SwitchRow(label: "Show a link’s address when pointing at it", isOn: $prefs.showsLinkPreview)
            Line()
            SwitchRow(label: "Preview a tab’s page when pointing at it", isOn: $prefs.showsTabPreviews)
        }
        Group(title: "Split View", footer: "Right-click a tab and choose Split Left or Split Right, then pick the tab for the other side. Drag the divider to resize; right-click again to separate them.") {
            Row(label: "Two pages side by side") { Text("Right-click a tab").foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Video

private struct VideoPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Group(title: "Picture in Picture", footer: "A video playing in the tab you leave keeps playing in a floating window, and goes back into the page when you return.") {
            SwitchRow(label: "Float playing video when you switch tabs", isOn: $prefs.autoPictureInPicture)
        }
    }
}

// MARK: - Memory

private struct MemoryPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Group(title: "Claude", footer: "claude.ai stays loaded out of sight, so any Claude link opens at once. Uses about as much memory as one open tab.") {
            SwitchRow(label: "Keep Claude ready", isOn: $prefs.keepsClaudeReady)
        }
        Group(title: "Sleeping Tabs", footer: "A sleeping tab gives its memory back and wakes with its place and history when you click it, or as soon as you point at it. Tabs playing sound or using the camera never sleep.") {
            SwitchRow(label: "Put idle tabs to sleep", isOn: $prefs.sleepsTabs)
            if prefs.sleepsTabs {
                Line()
                Row(label: "After") {
                    Picker("", selection: $prefs.sleepAfterMinutes) {
                        ForEach([15, 30, 45, 60, 120, 240], id: \.self) {
                            Text($0 < 60 ? "\($0) minutes" : "\($0 / 60) hour\($0 == 60 ? "" : "s")").tag($0)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }
}

// MARK: - Passwords

private struct PasswordsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var passwords = ApplePasswords.shared
    @State private var code = ""

    var body: some View {
        Group(title: "iCloud Passwords", footer: "Sill asks Apple’s Passwords app for a site’s accounts when you click a sign-in box, and fills one only when you pick it. The connection lasts until Sill quits.") {
            SwitchRow(label: "Offer passwords from iCloud Keychain", isOn: $prefs.applePasswords)
            if prefs.applePasswords {
                Line()
                pairing
            }
        }
        Group(title: "Passkeys") {
            Row(label: "Status") {
                Text(ApplePasswords.entitled ? "Ready" : "Waiting on Apple’s approval").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var pairing: some View {
        switch passwords.state {
        case .idle where !ApplePasswords.entitled:
            VStack(alignment: .leading, spacing: 6) {
                Text("Waiting on Apple’s approval").font(.system(size: 14))
                Text("macOS lets only browsers Apple has approved read iCloud Keychain and use passkeys. Sill’s request is in; once granted, its profile goes beside build.sh as Sill.provisionprofile.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        case .idle:
            Row(label: passwords.trouble ?? "Not connected") {
                Button("Connect…") { Task { await passwords.connect() } }
            }
        case .starting:
            Row(label: "Starting…") { ProgressView().controlSize(.small) }
        case .code, .checking:
            Row(label: "Enter the six-digit code macOS shows") {
                HStack {
                    TextField("Code", text: $code)
                        .textFieldStyle(.bordered)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 100)
                        .onSubmit(pair)
                        .onChange(of: code) { _, value in if value.filter(\.isNumber).count == 6 { pair() } }
                    Button("Connect", action: pair)
                        .buttonStyle(.glassProminent)
                        .disabled(code.filter(\.isNumber).count != 6 || passwords.state == .checking)
                }
            }
        case .paired:
            Row(label: "Connected to Apple Passwords") {
                Button("Disconnect") { passwords.disconnect() }
            }
        }
    }

    private func pair() {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6, passwords.state == .code else { return }
        code = ""
        Task { await passwords.enter(digits) }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var shield = Shield.shared
    @State private var cleared: String?
    @State private var paused: [String] = Shield.shared.paused.sorted()

    var body: some View {
        Group(title: "Ads and Trackers", footer: "Sill blocks a short list of advertising and tracking companies when another site loads them, and hides the empty boxes left behind. YouTube is left alone. Right-click a tab to turn it off for one site.") {
            SwitchRow(label: "Block ads and trackers", isOn: $prefs.blocksAds)
            if prefs.blocksAds, let trouble = shield.trouble {
                Line()
                Row(label: "Nothing is blocked: \(trouble)") { Button("Try Again") { shield.tryAgain() } }
            }
        }
        if !paused.isEmpty {
            Group(title: "Blocking Turned Off") {
                ForEach(Array(paused.enumerated()), id: \.element) { index, host in
                    if index > 0 { Line() }
                    Row(label: host) {
                        Button("Block Again") {
                            Shield.shared.pause(host, false)
                            paused = Shield.shared.paused.sorted()
                        }
                    }
                }
            }
        }
        Group(title: "History and Website Data", footer: cleared) {
            Row(label: "History") { Button("Clear History…") { AppDelegate.shared.clearHistory(nil) } }
            Line()
            Row(label: "Cookies and website data") { Button("Clear…") { clearWebsiteData() } }
        }
        Group(footer: "A private window keeps its cookies in memory and writes no history.") {
            Row(label: "Private windows") { Text("⇧⌘N").foregroundStyle(.secondary) }
        }
        .onAppear { paused = Shield.shared.paused.sorted() }
    }

    private func clearWebsiteData() {
        let alert = NSAlert()
        alert.messageText = "Clear cookies and website data?"
        alert.informativeText = "You’ll be signed out of websites. History and open tabs stay."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            cleared = "Website data cleared."
        }
    }
}

// MARK: - Agents

private struct AgentsPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var copied = false

    private var helper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sill-mcp").path
    }

    var body: some View {
        Group(title: "Agent Control", footer: "AI agents on this Mac (Claude Code, Codex, any MCP client) can open tabs, read pages, click, type and take screenshots through Sill. Only programs running as you can connect, nothing listens on the network, and private windows are never visible.") {
            SwitchRow(label: "Allow agents to control Sill", isOn: $prefs.agentControl)
        }
        Group(title: "Connect an Agent", footer: "Paste the command into a terminal once; the agent then sees Sill’s tools. AGENTS.md in Sill’s repository lists every tool.") {
            Row(label: "Claude Code", detail: "claude mcp add sill -- \(helper)") {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("claude mcp add sill -- \"\(helper)\"", forType: .string)
                    copied = true
                }
            }
            Line()
            Row(label: "Other MCP clients", detail: helper) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: helper)]) }
            }
        }
    }
}

// MARK: - Import

private struct ImportPane: View {
    @ObservedObject private var importer = SafariImport.shared
    @State private var history = true
    @State private var bookmarks = true
    @State private var cookies = true
    @State private var tabs = false
    @State private var access = SafariImport.shared.hasAccess

    var body: some View {
        Group(title: "From Safari", footer: "Nothing leaves your Mac. Safari’s cache can’t be reused by another browser; pages rebuild it as you visit them.") {
            SwitchRow(label: "History", isOn: $history)
            Line()
            SwitchRow(label: "Bookmarks", isOn: $bookmarks)
            Line()
            SwitchRow(label: "Cookies (stay signed in)", isOn: $cookies)
            Line()
            SwitchRow(label: "Tabs open in Safari now", isOn: $tabs)
        }
        if !access {
            Group(footer: "Safari keeps these files where only apps with Full Disk Access can read them.") {
                Row(label: "Sill needs Full Disk Access") {
                    HStack {
                        Button("Check Again") { access = importer.hasAccess }
                        Button("Open Privacy Settings") { importer.openPrivacySettings() }
                    }
                }
            }
        }
        Group(footer: importer.report) {
            Row(label: "Bring it over") {
                HStack {
                    if importer.running { ProgressView().controlSize(.small) }
                    Button("Import") { importer.run(history: history, bookmarks: bookmarks, cookies: cookies, tabs: tabs) }
                        .buttonStyle(.glassProminent)
                        .disabled(importer.running || (!history && !bookmarks && !cookies && !tabs) || (!access && !tabs))
                }
            }
        }
        .onAppear { access = importer.hasAccess }
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        switch (info?["CFBundleShortVersionString"] as? String, info?["CFBundleVersion"] as? String) {
        case let (short?, build?): return "Version \(short) (\(build))"
        case let (short?, nil): return "Version \(short)"
        default: return "Development build"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
            Text("Sill").font(.system(size: 20, weight: .semibold))
            Text(version).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
        Group {
            Row(label: "Source code") { Link("GitHub", destination: URL(string: "https://github.com/costoudesiason/sill")!) }
            Line()
            Row(label: "What’s new") { Link("Releases", destination: URL(string: "https://github.com/costoudesiason/sill/releases")!) }
        }
    }
}

enum SettingsSupport {
    static var isDefaultBrowser: Bool {
        guard let http = URL(string: "http://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: http) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
}
