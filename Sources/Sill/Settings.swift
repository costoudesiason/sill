import AppKit
import SwiftUI
import WebKit

/// Settings as one window, laid out like System Settings: a full-height
/// sidebar of panes on the left, and the chosen pane's grouped controls on
/// the right. Everything applies as you change it.
@MainActor
enum SettingsWindow {
    static let size = NSSize(width: 720, height: 560)

    static func make() -> NSWindowController {
        let host = NSHostingController(rootView: SettingsView())
        // The window keeps its own size; panes of different lengths scroll
        // rather than making the window jump as you move between them.
        host.sizingOptions = []
        // Nothing from SwiftUI goes into the window's toolbar: the pane's
        // title lives in the pane, and settings have no sidebar button.
        host.sceneBridgingOptions = []

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "Settings"
        window.titleVisibility = .hidden
        // A clear title bar so the sidebar's glass runs from the very top,
        // with the traffic lights sitting on it.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty toolbar only makes the title bar as tall as a modern
        // window's, so the traffic lights line up with each pane's title.
        window.toolbar = NSToolbar(identifier: "SettingsToolbar")
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        // Comes back where and how big you left it.
        window.setFrameAutosaveName("SettingsWindow")
        return NSWindowController(window: window)
    }
}

// MARK: - Panes

/// Every pane in the sidebar, in order, with its tile.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, tabs, video, memory
    case passwords, privacy
    case importing, about
    // Agents: another change adds this pane as `AgentsSettingsSection`.
    // To turn it on, uncomment this case and the two marked lines below
    // (the sidebar row and the detail view).
    // case agents

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
        case .importing: "Import"
        case .about: "About"
        // case .agents: "Agents"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "paintbrush.fill"
        case .tabs: "square.on.square.fill"
        case .video: "play.rectangle.fill"
        case .memory: "memorychip.fill"
        case .passwords: "key.fill"
        case .privacy: "hand.raised.fill"
        case .importing: "square.and.arrow.down.fill"
        case .about: "info"
        // case .agents: "sparkles"
        }
    }

    /// Tile colours follow System Settings: grey for the app's own plumbing,
    /// a hue for each topic so a pane is easy to find again by colour.
    var tint: Color {
        switch self {
        case .general, .about: .gray
        case .appearance: .blue
        case .tabs: .indigo
        case .video: .red
        case .memory: .green
        case .passwords: .gray
        case .privacy: .blue
        case .importing: .orange
        // case .agents: .purple
        }
    }
}

/// The small rounded-square tile with a white symbol, as System Settings
/// shows beside each pane. Its colour names the pane, so it stays fixed
/// rather than following the accent colour.
private struct PaneTile: View {
    let pane: SettingsPane
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(pane.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Window content

private struct SettingsView: View {
    /// The pane you were on last time, so Settings reopens where you left it.
    @AppStorage("settingsPane") private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: selection) {
                row(.general)
                Section("Browsing") {
                    row(.appearance)
                    row(.tabs)
                    row(.video)
                    row(.memory)
                }
                Section("Privacy & Security") {
                    row(.passwords)
                    row(.privacy)
                    // row(.agents)  // Agents pane: see SettingsPane.
                }
                Section("Sill") {
                    row(.importing)
                    row(.about)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            PaneDetail(pane: pane)
                // A fresh view per pane, so scroll position and transient
                // state (a half-typed pairing code) don't leak across panes.
                .id(pane)
        }
    }

    /// The list wants an optional selection; there is always a pane, so
    /// clicking empty space keeps the one you're on.
    private var selection: Binding<SettingsPane?> {
        Binding(get: { pane }, set: { if let new = $0 { pane = new } })
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label { Text(pane.title) } icon: { PaneTile(pane: pane) }
            .tag(pane)
    }
}

/// The pane's title over its grouped form. The title sits in the title bar's
/// band, level with the traffic lights, and stays put while the form scrolls
/// beneath a hard edge, as titles in macOS 27 do.
private struct PaneDetail: View {
    let pane: SettingsPane

    var body: some View {
        content
            .formStyle(.grouped)
            .safeAreaBar(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    PaneTile(pane: pane, size: 24)
                    Text(pane.title).font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(height: 52)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .tabs: TabsPane()
        case .video: VideoPane()
        case .memory: MemoryPane()
        case .passwords: PasswordsPane()
        case .privacy: PrivacyPane()
        case .importing: ImportPane()
        case .about: AboutPane()
        // case .agents: Form { AgentsSettingsSection() }  // Agents pane: see SettingsPane.
        }
    }
}

/// Footers are small grey notes that explain a choice, under its group.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var isDefault = SettingsSupport.isDefaultBrowser

    var body: some View {
        Form {
            Section("Search") {
                Picker("Search engine", selection: $prefs.engine) {
                    ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Suggest searches as you type", isOn: $prefs.suggestions)
            }
            Section("Startup") {
                Toggle("Reopen tabs from last time", isOn: $prefs.restoresTabs)
            }
            Section("Default Browser") {
                LabeledContent(isDefault ? "Sill is your default browser" : "Open links from other apps in Sill") {
                    Button("Make Default") {
                        AppDelegate.shared.makeDefaultBrowser(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isDefault = SettingsSupport.isDefaultBrowser }
                    }
                    .disabled(isDefault)
                }
            }
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $prefs.theme) {
                    ForEach(Theme.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("See the desktop through the bar", isOn: $prefs.glassBar)
                if prefs.glassBar {
                    LabeledContent("Glass") {
                        HStack(spacing: 8) {
                            Text("Clear").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $prefs.glassWash, in: 0...0.9)
                            Text("Tinted").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 240)
                    }
                }
            } header: {
                Text("Bar")
            } footer: {
                Note("The bar lets your desktop show through, as Finder’s sidebar does. Clear lets more through; tinted calms it toward the window’s colour.")
            }
            Section {
                Toggle("Rounder corners", isOn: $prefs.roundCorners)
                if prefs.roundCorners {
                    LabeledContent("Roundness") {
                        HStack(spacing: 8) {
                            Slider(value: $prefs.cornerRadius, in: 14...36, step: 1)
                            Text("\(Int(prefs.cornerRadius)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        }
                        .frame(width: 240)
                    }
                }
            } header: {
                Text("Window")
            } footer: {
                Note("Rounder corners make the window see-through, which costs some smoothness while pages scroll. Off is fastest.")
            }
        }
    }
}

// MARK: - Tabs

private struct TabsPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Tab Bar") {
                Picker("Tab width", selection: $prefs.tabWidth) {
                    ForEach(TabWidth.allCases) { Text($0.name).tag($0) }
                }
                Picker("Close buttons", selection: $prefs.closeButtons) {
                    ForEach(CloseButtons.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Show a link’s address when pointing at it", isOn: $prefs.showsLinkPreview)
            }
            Section {
                LabeledContent("Two pages side by side") {
                    Text("Right-click a tab").foregroundStyle(.secondary)
                }
            } header: {
                Text("Split View")
            } footer: {
                Note("Choose Split Left or Split Right from a tab’s menu, then pick the page for the other side. Separate Split View puts them back.")
            }
        }
    }
}

// MARK: - Video

private struct VideoPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Float playing video when you switch tabs", isOn: $prefs.autoPictureInPicture)
            } header: {
                Text("Picture in Picture")
            } footer: {
                Note("A video playing in the tab you leave keeps playing in Picture in Picture, and goes back into the page when you return.")
            }
        }
    }
}

// MARK: - Memory

private struct MemoryPane: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Toggle("Put idle tabs to sleep", isOn: $prefs.sleepsTabs)
                if prefs.sleepsTabs {
                    Picker("After", selection: $prefs.sleepAfterMinutes) {
                        ForEach([15, 30, 45, 60, 120, 240], id: \.self) { Text($0 < 60 ? "\($0) minutes" : "\($0 / 60) hour\($0 == 60 ? "" : "s")").tag($0) }
                    }
                }
            } header: {
                Text("Sleeping Tabs")
            } footer: {
                Note("A sleeping tab gives its memory back and reloads when you click it. Tabs playing sound or using the camera never sleep.")
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
        Form {
            Section {
                Toggle("Offer passwords from iCloud Keychain", isOn: $prefs.applePasswords)
                if prefs.applePasswords { pairing }
            } header: {
                Text("iCloud Passwords")
            } footer: {
                Note("Sill asks Apple’s Passwords app for a site’s accounts when you click a sign-in box, and fills one only when you pick it. The connection lasts until Sill quits.")
            }
            Section("Passkeys") {
                LabeledContent("Status") {
                    Text(ApplePasswords.entitled ? "Ready" : "Waiting on Apple’s approval")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var pairing: some View {
        switch passwords.state {
        case .idle where !ApplePasswords.entitled:
            VStack(alignment: .leading, spacing: 6) {
                Label("Waiting on Apple’s approval", systemImage: "key.icloud")
                Text("macOS lets only browsers Apple has approved read iCloud Keychain and use passkeys. Once Apple grants Sill’s browser entitlement, put its profile beside build.sh as Sill.provisionprofile and rebuild.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Link("Apple’s request form", destination: URL(string: "https://developer.apple.com/contact/request/macos-browsers-passkeys/")!)
                    .font(.callout)
            }
        case .idle:
            LabeledContent(passwords.trouble ?? "Not connected") {
                Button("Connect…") { Task { await passwords.connect() } }
            }
        case .starting:
            LabeledContent("Starting…") { ProgressView().controlSize(.small) }
        case .code, .checking:
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the six-digit code macOS is showing.")
                HStack {
                    TextField("Code", text: $code)
                        .textFieldStyle(.bordered)
                        .font(.system(.title3, design: .monospaced))
                        .frame(width: 120)
                        .onSubmit(pair)
                        .onChange(of: code) { _, value in if value.filter(\.isNumber).count == 6 { pair() } }
                    Button("Connect", action: pair)
                        .buttonStyle(.glassProminent)
                        .disabled(code.filter(\.isNumber).count != 6 || passwords.state == .checking)
                    Button("Cancel") { passwords.disconnect() }
                    if passwords.state == .checking { ProgressView().controlSize(.small) }
                }
            }
        case .paired:
            LabeledContent {
                Button("Disconnect") { passwords.disconnect() }
            } label: {
                Label("Connected to Apple Passwords", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
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
    /// Shield doesn't announce changes to its paused sites, so the pane keeps
    /// its own copy and refreshes it when it changes one or appears.
    @State private var paused: [String] = Shield.shared.paused.sorted()

    var body: some View {
        Form {
            Section {
                Toggle("Block ads and trackers", isOn: $prefs.blocksAds)
                if prefs.blocksAds, let trouble = shield.trouble {
                    LabeledContent {
                        Button("Try Again") { shield.tryAgain() }
                    } label: {
                        Text("Nothing is blocked: \(trouble)").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Ads")
            } footer: {
                Note("Sill blocks a short list of advertising and tracking companies when another site loads them, and hides the empty boxes left behind. YouTube is left alone. Right-click a tab to turn it off for one site.")
            }
            if !paused.isEmpty {
                Section {
                    ForEach(paused, id: \.self) { host in
                        LabeledContent(host) {
                            Button("Block Again") {
                                Shield.shared.pause(host, false)
                                paused = Shield.shared.paused.sorted()
                            }
                        }
                    }
                } header: {
                    Text("Blocking Turned Off")
                } footer: {
                    Note("Ads show on these sites. Pages already open there pick up the change when they reload.")
                }
            }
            Section("History and Website Data") {
                LabeledContent("History") {
                    Button("Clear History…") { AppDelegate.shared.clearHistory(nil) }
                }
                LabeledContent("Cookies and website data") {
                    Button("Clear…") { clearWebsiteData() }
                }
                if let cleared {
                    Text(cleared).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Private windows") {
                    Text("⇧⌘N").foregroundStyle(.secondary)
                }
            } footer: {
                Note("A private window keeps its cookies in memory and writes no history.")
            }
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
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            cleared = "Website data cleared."
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
        Form {
            Section {
                Toggle("History", isOn: $history)
                Toggle("Bookmarks", isOn: $bookmarks)
                Toggle("Cookies (stay signed in)", isOn: $cookies)
                Toggle("Tabs open in Safari now", isOn: $tabs)
            } header: {
                Text("From Safari")
            } footer: {
                Note("Nothing leaves your Mac. Safari’s cache can’t be reused by another browser; pages rebuild it as you visit them. Passwords stay in iCloud Keychain, where Sill reads them once Apple approves it.")
            }
            if !access {
                Section {
                    LabeledContent("Sill needs Full Disk Access to read Safari’s files.") {
                        Button("Open Privacy Settings") { importer.openPrivacySettings() }
                    }
                    Button("Check Again") { access = importer.hasAccess }
                }
            }
            Section {
                HStack {
                    if let report = importer.report { Text(report).foregroundStyle(.secondary) }
                    Spacer()
                    if importer.running { ProgressView().controlSize(.small) }
                    Button("Import") {
                        importer.run(history: history, bookmarks: bookmarks, cookies: cookies, tabs: tabs)
                    }
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
    private static let repository = URL(string: "https://github.com/costoudesiason/sill")!
    private static let releases = URL(string: "https://github.com/costoudesiason/sill/releases")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "Version \(short) (\(build))"
        case let (short?, nil): return "Version \(short)"
        // Run straight from `swift build` there is no Info.plist to read.
        default: return "Development build"
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    Text("Sill").font(.title2.weight(.semibold))
                    Text(version).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                LabeledContent("Source code") {
                    Link("GitHub", destination: Self.repository)
                }
                LabeledContent("What’s new") {
                    Link("Releases", destination: Self.releases)
                }
            }
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
