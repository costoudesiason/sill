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
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 600, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Sill Passwords")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: PasswordsView(model: model))
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

    func copyPassword(_ login: SavedPasswords.Login) async {
        guard await unlock("copy your password for \(Domains.bare(login.host))"),
              let password = await SavedPasswords.password(for: login) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        // As Safari does: the copied password leaves the clipboard after a while.
        let count = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Domains.bare(login.host)).lineLimit(1)
                        Text(login.user.isEmpty ? "No user name" : login.user).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(login)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $model.search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if model.logins.isEmpty {
                    ContentUnavailableView("No Passwords", systemImage: "key",
                                           description: Text("Passwords you save in Sill, or import from Dia, appear here."))
                }
            }
        } detail: {
            if let login = model.selection {
                detail(login)
            } else {
                ContentUnavailableView("No Password Selected", systemImage: "key")
            }
        }
        .frame(minWidth: 600, minHeight: 380)
    }

    private func detail(_ login: SavedPasswords.Login) -> some View {
        Form {
            Section {
                LabeledContent("Website", value: login.host)
                LabeledContent("User Name") {
                    HStack {
                        Text(login.user.isEmpty ? "—" : login.user).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(login.user, forType: .string)
                        }
                        .disabled(login.user.isEmpty)
                    }
                }
                LabeledContent("Password") {
                    HStack {
                        Text(model.shown ?? String(repeating: "•", count: 10)).monospaced().textSelection(.enabled)
                        Button(model.shown == nil ? "Show" : "Hide") { Task { await model.reveal(login) } }
                        Button("Copy") { Task { await model.copyPassword(login) } }
                    }
                }
            } header: {
                Text(Domains.bare(login.host)).font(.title2.weight(.semibold)).foregroundStyle(.primary)
            }
            Section {
                Button("Delete Password…", role: .destructive) { confirmingDelete = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the password for \(Domains.bare(login.host))?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete(login) } }
        } message: {
            Text("It's removed from your Keychain. This can't be undone.")
        }
    }
}
