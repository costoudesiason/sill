import AppKit
import SwiftUI
import WebKit

/// Settings, as the Mac's own apps lay them out: a toolbar of panes, each a
/// grouped form of standard controls. Everything applies as you change it.
@MainActor
enum SettingsWindow {
    static func make() -> NSWindowController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        func pane<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view.frame(width: 560).fixedSize(horizontal: false, vertical: true))
            host.sizingOptions = .preferredContentSize
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        pane("General", "gearshape", GeneralPane())
        pane("Appearance", "paintbrush", AppearancePane())
        pane("Tabs", "square.on.square", TabsPane())
        pane("Passwords", "key", PasswordsPane())
        pane("Import", "square.and.arrow.down", ImportPane())
        pane("Privacy", "hand.raised", PrivacyPane())
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
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
        .formStyle(.grouped)
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
                        .frame(width: 260)
                    }
                }
            } header: {
                Text("Bar")
            } footer: {
                Text("The bar lets your desktop show through, as Finder’s sidebar does. Clear lets more through; tinted calms it toward the window’s colour.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Rounder corners", isOn: $prefs.roundCorners)
                if prefs.roundCorners {
                    LabeledContent("Roundness") {
                        HStack(spacing: 8) {
                            Slider(value: $prefs.cornerRadius, in: 14...36, step: 1)
                            Text("\(Int(prefs.cornerRadius)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        }
                        .frame(width: 260)
                    }
                }
            } header: {
                Text("Window")
            } footer: {
                Text("Rounder corners make the window see-through, which macOS redraws in full on every frame. Off is fastest.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Toggle("Float playing video when you switch tabs", isOn: $prefs.autoPictureInPicture)
            } header: {
                Text("Video")
            } footer: {
                Text("A video playing in the tab you leave keeps playing in Picture in Picture, and goes back into the page when you return.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Put idle tabs to sleep", isOn: $prefs.sleepsTabs)
                if prefs.sleepsTabs {
                    Picker("After", selection: $prefs.sleepAfterMinutes) {
                        ForEach([15, 30, 45, 60, 120, 240], id: \.self) { Text($0 < 60 ? "\($0) minutes" : "\($0 / 60) hour\($0 == 60 ? "" : "s")").tag($0) }
                    }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("A sleeping tab gives its memory back and reloads when you click it. Tabs playing sound or using the camera never sleep.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                Text("Sill asks Apple’s Passwords app for a site’s accounts when you click a sign-in box, and fills one only when you pick it. The connection lasts until Sill quits.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Passkeys") {
                LabeledContent("Status") {
                    Text(ApplePasswords.entitled ? "Ready" : "Waiting on Apple’s approval")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
                Text("Nothing leaves your Mac. Safari’s cache can’t be reused by another browser; pages rebuild it as you visit them. Passwords stay in iCloud Keychain, where Sill reads them once Apple approves it.")
                    .font(.footnote).foregroundStyle(.secondary)
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
        .formStyle(.grouped)
        .onAppear { access = importer.hasAccess }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @State private var cleared: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("History") {
                    Button("Clear History…") { AppDelegate.shared.clearHistory(nil) }
                }
                LabeledContent("Cookies and website data") {
                    Button("Clear…") { clearWebsiteData() }
                }
            } footer: {
                if let cleared { Text(cleared).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                LabeledContent("Private windows") {
                    Text("⇧⌘N").foregroundStyle(.secondary)
                }
            } footer: {
                Text("A private window keeps its cookies in memory and writes no history.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

enum SettingsSupport {
    static var isDefaultBrowser: Bool {
        guard let http = URL(string: "http://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: http) else { return false }
        return app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
}
