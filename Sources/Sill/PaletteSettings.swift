import AppKit
import SwiftUI
import WebKit

/// Sill's settings, all of them, inside the ⌘T palette: the slider button in
/// its corner (or ⌘,) turns the card into this list, and the glass X at its
/// top right (or Esc) turns it back. Laid out the way Alcove's settings are:
/// rounded groups of 42-point rows with hairlines between, a title over
/// each group, a choice shown as its value with ⌃⌄ that opens Sill's own
/// glass menu, and picture cards for the look. Each icon's parts move when
/// the pointer comes onto its row (Icons.swift).
struct PaletteSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var passwords = ApplePasswords.shared
    @ObservedObject private var importer = SafariImport.shared
    @ObservedObject private var connector = ConnectorBridge.shared
    var onChoose: (Choice, CGRect) -> Void
    @State private var code = ""
    @State private var isDefault = SettingsSupport.isDefaultBrowser
    @State private var cleared = false
    @State private var copied = false
    @State private var copiedConnector = false
    @State private var signedOut = false
    @State private var forgotHabits = false

    enum Choice { case engine }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Settings").font(.system(size: 21))
                Spacer()
            }
            .padding(.leading, 24)
            .frame(height: Palette.fieldHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsGroup {
                        ChoiceRow(icon: .search, tint: .blue, title: "Search with", value: prefs.engine.name) {
                            onChoose(.engine, $0)
                        }
                        Hairline()
                        LookCards(selection: $prefs.theme)
                        Hairline()
                        SwitchRow(icon: .corners, tint: .gray, title: "Rounder corners",
                                  detail: "The window turns see-through, which costs some smoothness",
                                  isOn: $prefs.roundCorners)
                    }

                    GroupTitle("Tabs")
                    SettingsGroup {
                        SwitchRow(icon: .reopen, tint: .mint, title: "Reopen tabs from last time", isOn: $prefs.restoresTabs)
                        Hairline()
                        SwitchRow(icon: .previews, tint: .teal, title: "Preview a tab when pointing at it", isOn: $prefs.showsTabPreviews)
                        Hairline()
                        SwitchRow(icon: .pip, tint: .orange, title: "Float playing video when you switch tabs",
                                  isOn: $prefs.autoPictureInPicture)
                        Hairline()
                        SwitchRow(icon: .sleep, tint: .indigo, title: "Put idle tabs to sleep",
                                  detail: "After two hours; they wake as you point at them", isOn: $prefs.sleepsTabs)
                        Hairline()
                        SwitchRow(icon: .claude, tint: .orange, title: "Keep Claude ready",
                                  detail: "claude.ai links open at once", isOn: $prefs.keepsClaudeReady)
                    }

                    GroupTitle("Privacy")
                    SettingsGroup {
                        SwitchRow(icon: .shield, tint: .green, title: "Block ads and trackers", isOn: $prefs.blocksAds)
                        Hairline()
                        SwitchRow(icon: .key, tint: .yellow, title: "Passwords from iCloud Keychain", isOn: $prefs.applePasswords)
                        if prefs.applePasswords {
                            Hairline()
                            passwordsRow
                        }
                        Hairline()
                        ActionRow(icon: .permissions, tint: .blue, title: "Reset website permissions…") {
                            AppDelegate.shared.resetSitePermissions(nil)
                        }
                        Hairline()
                        ActionRow(icon: .history, tint: .gray, title: "Clear history…") { AppDelegate.shared.clearHistory(nil) }
                        Hairline()
                        ActionRow(icon: .trash, tint: .red, title: "Clear cookies and website data…",
                                  value: cleared ? "Cleared" : nil) { clearWebsiteData() }
                    }

                    GroupTitle("Sill")
                    SettingsGroup {
                        if !isDefault {
                            ActionRow(icon: .globe, tint: .blue, title: "Make Sill your default browser") {
                                AppDelegate.shared.makeDefaultBrowser(nil)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { isDefault = SettingsSupport.isDefaultBrowser }
                            }
                            Hairline()
                        }
                        ActionRow(icon: .importing, tint: .cyan,
                                  title: importer.running ? "Importing from Safari…" : "Import from Safari",
                                  value: importer.report) { importFromSafari() }
                        Hairline()
                        SwitchRow(icon: .terminal, tint: .gray, title: "Allow agents to control Sill",
                                  detail: "Claude Code, Codex and other MCP clients on this Mac", isOn: $prefs.agentControl)
                        if prefs.agentControl {
                            Hairline()
                            ActionRow(icon: .copy, tint: .gray, title: "Copy the command for Claude Code",
                                      value: copied ? "Copied" : nil) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("claude mcp add sill -- \(SettingsSupport.mcpHelper)", forType: .string)
                                copied = true
                            }
                            Hairline()
                            SwitchRow(icon: .claude, tint: .orange, title: "Let claude.ai control Sill",
                                      detail: prefs.remoteConnector ? connector.summary : "A custom connector, through your own relay",
                                      isOn: $prefs.remoteConnector)
                            Hairline()
                            ActionRow(icon: .history, tint: .gray, title: "Agent activity", value: "Show") { AgentLog.show() }
                            Hairline()
                            SwitchRow(icon: .importing, tint: .blue, title: "Let agents find and read my files",
                                      detail: "Desktop, Documents, Downloads, Pictures, Movies, Music and iCloud Drive",
                                      isOn: $prefs.agentFiles)
                            Hairline()
                            SwitchRow(icon: .history, tint: .indigo, title: "Learn from what I do",
                                      detail: "What you click on your sites and where it goes, so agents know the way. On this Mac only",
                                      isOn: $prefs.learnsHabits)
                            if prefs.learnsHabits {
                                Hairline()
                                ActionRow(icon: .trash, tint: .gray, title: "Forget what Sill learned",
                                          value: forgotHabits ? "Forgotten" : nil) {
                                    Habits.shared.forget()
                                    forgotHabits = true
                                }
                            }
                            if prefs.remoteConnector {
                                Hairline()
                                SwitchRow(icon: .code, tint: .gray, title: "Let claude.ai run scripts in pages",
                                          detail: "Off: it uses Sill’s tools, which Sill can check", isOn: $prefs.remoteScripts)
                                Hairline()
                                ActionRow(icon: .key, tint: .red, title: "Sign out claude.ai",
                                          value: signedOut ? "Signed out" : nil) {
                                    ConnectorBridge.shared.signEveryoneOut()
                                    signedOut = true
                                }
                                Hairline()
                                ActionRow(icon: .link, tint: .gray, title: "Relay",
                                          value: ConnectorBridge.relayOrigin.flatMap { URL(string: $0)?.host } ?? "Set Up…") {
                                    ConnectorSetup.run()
                                }
                                if let address = ConnectorBridge.connectorAddress {
                                    Hairline()
                                    ActionRow(icon: .copy, tint: .gray, title: "Copy the connector address",
                                              value: copiedConnector ? "Copied" : nil) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(address, forType: .string)
                                        copiedConnector = true
                                    }
                                }
                            }
                        }
                        Hairline()
                        ActionRow(icon: .code, tint: .gray, title: "Sill \(SettingsSupport.version)", value: "GitHub") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/costoudesiason/sill")!)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
        }
        .coordinateSpace(.named("settings"))
    }

    @ViewBuilder private var passwordsRow: some View {
        switch passwords.state {
        case .idle where !ApplePasswords.entitled:
            NoteRow(text: "Passkeys are waiting on Apple’s approval for Sill.")
        case .idle:
            ActionRow(icon: .link, tint: .yellow, title: "Connect to Apple Passwords", value: passwords.trouble) {
                Task { await passwords.connect() }
            }
        case .starting:
            NoteRow(text: "Connecting…")
        case .code, .checking:
            HStack {
                Text("Enter the code macOS shows").font(.system(size: 13))
                Spacer()
                TextField("000000", text: $code)
                    .textFieldStyle(.bordered)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit(pair)
                    .onChange(of: code) { _, value in if value.filter(\.isNumber).count == 6 { pair() } }
            }
            .padding(.leading, 48)
            .padding(.trailing, 14)
            .frame(height: 42)
        case .paired:
            ActionRow(icon: .connected, tint: .green, title: "Connected to Apple Passwords", value: "Disconnect") {
                passwords.disconnect()
            }
        }
    }

    private func pair() {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6, passwords.state == .code else { return }
        code = ""
        Task { await passwords.enter(digits) }
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
            cleared = true
        }
    }

    private func importFromSafari() {
        guard !importer.running else { return }
        guard importer.hasAccess else { return importer.openPrivacySettings() }
        importer.run(history: true, bookmarks: true, cookies: true, tabs: false)
    }
}

// MARK: - pieces (measured from Alcove's settings: 42 pt rows, 12 pt group
// corners, hairlines the group's width, titles 13 pt semibold above)

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct GroupTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.top, 18)
            .padding(.bottom, 7)
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }
}

/// The coloured square an icon sits in, as in Alcove's sidebar.
private struct Tile: View {
    let icon: IconKind
    let tint: Color
    let on: Bool
    var body: some View {
        HoverIcon(kind: icon, on: on, size: 13)
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
    }
}

private struct RowFrame<Trailing: View>: View {
    let icon: IconKind
    let tint: Color
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Tile(icon: icon, tint: tint, on: hovering)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: detail == nil ? 42 : 50)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct SwitchRow: View {
    let icon: IconKind, tint: Color, title: String
    var detail: String?
    @Binding var isOn: Bool
    var body: some View {
        RowFrame(icon: icon, tint: tint, title: title, detail: detail) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// A choice: its value and ⌃⌄, like Alcove's "All displays"; a click opens
/// Sill's glass menu under it.
private struct ChoiceRow: View {
    let icon: IconKind, tint: Color, title: String, value: String
    var choose: (CGRect) -> Void
    @State private var frame: CGRect = .zero

    var body: some View {
        RowFrame(icon: icon, tint: tint, title: title) {
            HStack(spacing: 6) {
                Text(value).font(.system(size: 13))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("settings")) } action: { frame = $0 }
        .onTapGesture { choose(frame) }
        .accessibilityAddTraits(.isButton)
    }
}

private struct ActionRow: View {
    let icon: IconKind, tint: Color, title: String
    var value: String?
    var run: () -> Void
    var body: some View {
        RowFrame(icon: icon, tint: tint, title: title) {
            HStack(spacing: 6) {
                if let value { Text(value).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .onTapGesture(perform: run)
        .accessibilityAddTraits(.isButton)
    }
}

private struct NoteRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 48)
            .frame(height: 36)
    }
}

/// The look, as Alcove shows its styles: a card for each with a small
/// picture, the chosen one ringed in the accent colour and its name bold.
private struct LookCards: View {
    @Binding var selection: Theme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Theme.allCases) { theme in
                VStack(spacing: 7) {
                    preview(theme)
                        .frame(height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                        .padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: selection == theme ? 2.5 : 0))
                    Text(theme.name)
                        .font(.system(size: 12.5, weight: selection == theme ? .semibold : .regular))
                        .foregroundStyle(selection == theme ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { selection = theme }
                .accessibilityAddTraits(selection == theme ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(theme.name)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    /// A tiny window: its bar and two lines of page, in that look's colours.
    @ViewBuilder private func preview(_ theme: Theme) -> some View {
        switch theme {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            HStack(spacing: 0) { MiniWindow(dark: false); MiniWindow(dark: true) }
        }
    }
}

private struct MiniWindow: View {
    let dark: Bool
    var body: some View {
        let page = dark ? Color(white: 0.12) : Color(white: 0.97)
        let ink = dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12)
        ZStack(alignment: .topLeading) {
            page
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink).frame(height: 6).padding(.trailing, 18)
                Capsule().fill(ink.opacity(0.7)).frame(height: 4).padding(.trailing, 30)
                Capsule().fill(ink.opacity(0.7)).frame(height: 4).padding(.trailing, 40)
            }
            .padding(10)
        }
    }
}
