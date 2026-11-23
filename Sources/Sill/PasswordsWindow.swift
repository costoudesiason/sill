import AppKit
import LocalAuthentication
import SwiftUI

/// Sill's own Passwords window: the accounts it keeps in your Keychain
/// (saved in Sill or brought over from Dia), laid out as Apple's Passwords
/// app lays out its own. A password shows or copies only after Touch ID or
/// your Mac password, once while the window is open.
@MainActor
final class PasswordsWindow: NSWindowController, NSWindowDelegate {
    private static var shared: PasswordsWindow?

    static func show() {
        let controller = shared ?? PasswordsWindow()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private let model = PasswordsModel()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Passwords"
        window.toolbarStyle = .unified
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 600, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Sill Passwords")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        let host = NSHostingController(rootView: PasswordsView(model: model))
        // The view's toolbar (Delete) and title become the window's.
        host.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = host
        window.delegate = self
        Task { await model.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        // Shown passwords hide again, and the next look asks again.
        model.forget()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        Task { await model.reload() }
    }
}

@MainActor
final class PasswordsModel: ObservableObject {
    @Published var logins: [SavedPasswords.Login] = []
    @Published var selection: SavedPasswords.Login?
    @Published var search = ""
    @Published var shown: String?
    private var unlocked = false

    var filtered: [SavedPasswords.Login] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return logins }
        return logins.filter { $0.host.lowercased().contains(query) || $0.user.lowercased().contains(query) }
    }

    func reload() async {
        logins = await SavedPasswords.all()
        if let selection, !logins.contains(selection) { self.selection = nil }
        if selection == nil { selection = logins.first }
    }

    func forget() {
        shown = nil
        unlocked = false
    }

    /// Touch ID or the Mac's password, once while the window is open.
    private func unlock(_ why: String) async -> Bool {
        if unlocked { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: why)) ?? false
        unlocked = ok
        return ok
    }

    func reveal(_ login: SavedPasswords.Login) async {
        if shown != nil { shown = nil; return }
        guard await unlock("show your password for \(Domains.bare(login.host))") else { return }
        shown = await SavedPasswords.password(for: login)
    }

    @discardableResult
    func copyPassword(_ login: SavedPasswords.Login) async -> Bool {
        guard await unlock("copy your password for \(Domains.bare(login.host))"),
              let password = await SavedPasswords.password(for: login) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        // As Safari does: the copied password leaves the clipboard after a while.
        let count = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
        return true
    }

    func delete(_ login: SavedPasswords.Login) async {
        guard await SavedPasswords.delete(login) else { return }
        shown = nil
        await reload()
    }
}

struct PasswordsView: View {
    @ObservedObject var model: PasswordsModel
    @State private var confirmingDelete = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.selection }, set: { model.selection = $0; model.shown = nil })) {
                ForEach(model.filtered, id: \.self) { login in
                    HStack(spacing: 10) {
                        SiteIcon(host: login.host, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Domains.bare(login.host)).lineLimit(1)
                            Text(login.user.isEmpty ? "No user name" : login.user)
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(login)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $model.search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
            .overlay {
                if model.logins.isEmpty {
                    ContentUnavailableView("No Passwords", systemImage: "key",
                                           description: Text("Passwords you save in Sill, or import from Dia, appear here."))
                }
            }
        } detail: {
            Group {
                if let login = model.selection {
                    detail(login)
                } else {
                    ContentUnavailableView("No Password Selected", systemImage: "key")
                }
            }
            .toolbar {
                ToolbarItem {
                    Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                        .help("Delete Password")
                        .disabled(model.selection == nil)
                }
            }
        }
        .navigationTitle("Passwords")
        .frame(minWidth: 600, minHeight: 380)
        .confirmationDialog("Delete the password for \(model.selection.map { Domains.bare($0.host) } ?? "")?",
                            isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { if let login = model.selection { Task { await model.delete(login) } } }
        } message: {
            Text("It's removed from your Keychain. This can't be undone.")
        }
    }

    private func detail(_ login: SavedPasswords.Login) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    SiteIcon(host: login.host, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Domains.bare(login.host)).font(.title2.weight(.semibold))
                        Text(login.host).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("User Name") {
                    HStack(spacing: 6) {
                        Text(login.user.isEmpty ? "—" : login.user).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        RowButton(symbol: "doc.on.doc", help: "Copy User Name", copies: true) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(login.user, forType: .string)
                            return true
                        }
                        .disabled(login.user.isEmpty)
                    }
                }
                LabeledContent("Password") {
                    HStack(spacing: 6) {
                        Text(model.shown ?? String(repeating: "•", count: 12))
                            .font(model.shown == nil ? .body : .body.monospaced())
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        RowButton(symbol: model.shown == nil ? "eye" : "eye.slash", help: model.shown == nil ? "Show Password" : "Hide Password") {
                            await model.reveal(login)
                            return true
                        }
                        RowButton(symbol: "doc.on.doc", help: "Copy Password", copies: true) { await model.copyPassword(login) }
                    }
                }
                LabeledContent("Website") {
                    Link(login.host, destination: URL(string: "https://\(login.host)/")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A small borderless icon button at the end of a row, as Passwords has.
/// A copy button answers: its icon turns to a checkmark for a moment, with
/// a light tap of the trackpad, once the copy has happened.
private struct RowButton: View {
    let symbol: String
    let help: String
    var copies = false
    let action: () async -> Bool
    @State private var done = false

    init(symbol: String, help: String, copies: Bool = false, action: @escaping () async -> Bool) {
        self.symbol = symbol
        self.help = help
        self.copies = copies
        self.action = action
    }

    var body: some View {
        Button {
            Task {
                guard await action(), copies else { return }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                withAnimation(.snappy) { done = true }
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(.snappy) { done = false }
            }
        } label: {
            Image(systemName: done ? "checkmark" : symbol)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(done ? "Copied" : help)
    }
}

/// The site's icon from Sill's favicon store, else its first letter on a
/// tile, as Passwords shows a site it has no icon for.
private struct SiteIcon: View {
    let host: String
    let size: CGFloat
    var body: some View {
        let image = URL(string: "https://\(host)/").flatMap { Favicons.shared.cached(for: $0) }
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(image == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background))
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(size * 0.14)
            } else {
                Text(String(Domains.bare(host).prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}
