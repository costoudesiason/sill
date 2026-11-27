import AppKit
import SwiftUI

/// Sill's settings, all of them, inside the ⌘T palette: the slider button in
/// its corner (or ⌘,) turns the card into this list, and the glass X at its
/// top right (or Esc) turns it back. Laid out the way Alcove's settings are:
/// rounded groups of 42-point rows with hairlines between, a title over
/// each group, a choice shown as its value with ⌃⌄ that opens Sill's own
/// glass menu, and picture cards for the look. The icons hold still.
/// Settings are one short list; what agents and claude.ai may do is a page
/// of its own, a row away.
final class SettingsNav: ObservableObject {
    enum Page { case main, agents }
    @Published var page: Page = .main
}

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

    enum Choice {
        case engine
        /// Clear browsing data's three choices; the second clears cookies and site data.
        case clear(data: () -> Void)
    }

    /// Which page is showing, shared with the palette: its back button is
    /// glass in the card's corner, as the X is (Palette).
    @ObservedObject var nav: SettingsNav
    private var page: SettingsNav.Page { nav.page }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(page == .agents ? "Agents" : "Settings").font(.system(size: 21))
                Spacer()
            }
            // After the glass back button on the Agents page.
            .padding(.leading, page == .agents ? 64 : 24)
            .frame(height: Palette.fieldHeight)

            ZStack {
                // Kept while Agents shows, so coming back finds it scrolled
                // where it was (rebuilt, it came back at the top).
                ScrollView { mainPage }
                    .opacity(page == .main ? 1 : 0)
                    .offset(x: page == .main ? 0 : -40)
                    .allowsHitTesting(page == .main)
                    .accessibilityHidden(page != .main)
                if page == .agents {
                    ScrollView { agentsPage }
                        .transition(Motion.reduced ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .scrollIndicators(.automatic)
            .clipped()
        }
        .coordinateSpace(.named("settings"))
        // "Copied", "Cleared", "Signed out": said for a moment, not for good.
        .onChange(of: copied) { _, on in if on { after { copied = false } } }
        .onChange(of: copiedConnector) { _, on in if on { after { copiedConnector = false } } }
        .onChange(of: cleared) { _, on in if on { after { cleared = false } } }
        .onChange(of: signedOut) { _, on in if on { after { signedOut = false } } }
    }

    private func after(_ reset: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                LookCards(selection: $prefs.theme)
                Hairline()
                ChoiceRow(icon: .search, tint: .blue, title: "Search with", value: prefs.engine.name) {
                    onChoose(.engine, $0)
                }
                Hairline()
                SwitchRow(icon: .corners, tint: .gray, title: "Rounder corners", isOn: $prefs.roundCorners)
            }

            GroupTitle("Tabs")
            SettingsGroup {
                SwitchRow(icon: .reopen, tint: .mint, title: "Reopen tabs from last time", isOn: $prefs.restoresTabs)
                Hairline()
                SwitchRow(icon: .previews, tint: .teal, title: "Preview tabs on hover", isOn: $prefs.showsTabPreviews)
                Hairline()
                SwitchRow(icon: .pip, tint: .orange, title: "Float video when you switch tabs", isOn: $prefs.autoPictureInPicture)
                Hairline()
                SwitchRow(icon: .sleep, tint: .indigo, title: "Sleep tabs idle for two hours", isOn: $prefs.sleepsTabs)
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
                clearRow
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
                ActionRow(icon: .terminal, tint: .gray, title: "Agents",
                          value: prefs.agentControl ? (prefs.remoteConnector ? "On, with claude.ai" : "On") : "Off") {
                    if Motion.reduced { nav.page = .agents } else { withAnimation(.smooth(duration: 0.28)) { nav.page = .agents } }
                }
                Hairline()
                ActionRow(icon: .permissions, tint: .gray, title: "Advanced settings", value: "Chromium") {
                    SEEngine.openChromiumSettings(nil)
                }
            }

            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/costoudesiason/sill")!)
            } label: {
                Text("Sill \(SettingsSupport.version)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Sill on GitHub")
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var agentsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
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
                }
            }

            if prefs.agentControl {
                GroupTitle("claude.ai")
                SettingsGroup {
                    SwitchRow(icon: .claude, tint: .orange, title: "Let claude.ai control Sill",
                              detail: prefs.remoteConnector ? connector.summary : "Through your own relay",
                              isOn: $prefs.remoteConnector)
                    if prefs.remoteConnector {
                        Hairline()
                        SwitchRow(icon: .code, tint: .gray, title: "Let it run scripts in pages", isOn: $prefs.remoteScripts)
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
                        Hairline()
                        ActionRow(icon: .key, tint: .red, title: "Sign out claude.ai",
                                  value: signedOut ? "Signed out" : nil) {
                            ConnectorBridge.shared.signEveryoneOut()
                            signedOut = true
                        }
                    }
                }
            }

            GroupTitle("Claude")
            SettingsGroup {
                SwitchRow(icon: .claude, tint: .orange, title: "Keep claude.ai ready",
                          detail: "Its links open at once", isOn: $prefs.keepsClaudeReady)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// History, cookies and site permissions: three ways to forget, one row.
    private var clearRow: some View {
        ChoiceRow(icon: .trash, tint: .red, title: "Clear browsing data", value: cleared ? "Cleared" : "Choose…") {
            onChoose(.clear(data: clearWebsiteData), $0)
        }
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
        SEEngine.clearWebsiteData { cleared = true }
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
    var body: some View {
        HoverIcon(kind: icon, on: false, size: 13)
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

    var body: some View {
        HStack(spacing: 12) {
            Tile(icon: icon, tint: tint)
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
    }
}

private struct SwitchRow: View {
    let icon: IconKind, tint: Color, title: String
    var detail: String?
    @Binding var isOn: Bool
    var body: some View {
        RowFrame(icon: icon, tint: tint, title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(frame) }
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { run() }
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
                        .frame(height: 64)
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

    /// Sill itself in miniature, in that look, on the desktop, as macOS
    /// shows its own appearances: the bar with its traffic lights, back and
    /// forward, tabs and buttons, and a page under it. System is both, cut
    /// across, light on the left.
    @ViewBuilder private func preview(_ theme: Theme) -> some View {
        switch theme {
        case .light: MiniSill(dark: false)
        case .dark: MiniSill(dark: true)
        case .system:
            ZStack {
                MiniSill(dark: true)
                MiniSill(dark: false).mask(
                    GeometryReader { g in
                        Path { p in
                            p.move(to: .zero)
                            p.addLine(to: CGPoint(x: g.size.width * 0.62, y: 0))
                            p.addLine(to: CGPoint(x: g.size.width * 0.38, y: g.size.height))
                            p.addLine(to: CGPoint(x: 0, y: g.size.height))
                        }
                    })
            }
        }
    }
}

private struct MiniSill: View {
    let dark: Bool

    var body: some View {
        let wallpaper = dark
            ? LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.32), Color(red: 0.32, green: 0.14, blue: 0.38)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(red: 0.55, green: 0.74, blue: 0.98), Color(red: 0.98, green: 0.76, blue: 0.82)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
        let bar = dark ? Color(white: 0.17) : Color(white: 0.92)
        let glass = dark ? Color(white: 0.30) : Color.white.opacity(0.95)
        let plain = dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
        let page = dark ? Color(white: 0.11) : Color.white
        let ink = dark ? Color.white.opacity(0.24) : Color.black.opacity(0.13)

        ZStack(alignment: .topLeading) {
            wallpaper
            // The window, running off the card's right and bottom edges.
            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    HStack(spacing: 2) {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                        Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                    }
                    .frame(width: 13, height: 3.5)
                    Capsule().fill(glass).frame(width: 13, height: 7)
                    Capsule().fill(glass).frame(height: 7)
                    Capsule().fill(plain).frame(height: 7)
                    Capsule().fill(plain).frame(height: 7)
                    Capsule().fill(glass).frame(width: 14, height: 7)
                }
                .padding(.horizontal, 4)
                .frame(height: 13)
                .background(bar)
                ZStack(alignment: .topLeading) {
                    page
                    VStack(alignment: .leading, spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5).fill(ink).frame(width: 34, height: 4)
                        HStack(alignment: .top, spacing: 4) {
                            VStack(alignment: .leading, spacing: 2.5) {
                                Capsule().fill(ink.opacity(0.7)).frame(height: 2.5)
                                Capsule().fill(ink.opacity(0.7)).frame(height: 2.5)
                                Capsule().fill(ink.opacity(0.7)).frame(width: 26, height: 2.5)
                            }
                            RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.55)).frame(width: 22, height: 15)
                        }
                    }
                    .padding(6)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
            .padding(.leading, 13)
            .padding(.top, 11)
            .padding(.trailing, -8)
            .padding(.bottom, -8)
        }
        .clipped()
    }
}
