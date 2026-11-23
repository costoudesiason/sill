import AppKit
import SwiftUI
import WebKit

/// The page's alert(), confirm() and prompt(), and HTTP sign-ins: the Mac's
/// own alert, as a sheet on the window, saying which site is asking.
@MainActor
enum Prompts {
    private static func alert(from frame: WKFrameInfo, message: String) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : "\(Domains.bare(host)) says"
        alert.informativeText = message
        return alert
    }

    static func alert(_ message: String, from frame: WKFrameInfo, in window: NSWindow?, _ done: @escaping () -> Void) {
        let alert = alert(from: frame, message: message)
        alert.addButton(withTitle: "OK")
        present(alert, in: window) { _ in done() }
    }

    static func confirm(_ message: String, from frame: WKFrameInfo, in window: NSWindow?, _ done: @escaping (Bool) -> Void) {
        let alert = alert(from: frame, message: message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert, in: window) { done($0 == .alertFirstButtonReturn) }
    }

    static func input(_ prompt: String, defaultText: String?, from frame: WKFrameInfo, in window: NSWindow?,
                      _ done: @escaping (String?) -> Void) {
        let alert = alert(from: frame, message: prompt)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, in: window) { done($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    static func credentials(for space: URLProtectionSpace, in window: NSWindow, _ done: @escaping (URLCredential?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        alert.informativeText = space.realm.map { "“\($0)” asks for a name and password." } ?? "This site asks for a name and password."
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "Name"
        user.contentType = .username
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        password.placeholderString = "Password"
        password.contentType = .password
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        stack.addSubview(user)
        stack.addSubview(password)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return done(nil) }
            done(URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
    }

    static func leave(in window: NSWindow?, _ done: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to leave this page?"
        alert.informativeText = "Changes you made may not be saved."
        alert.addButton(withTitle: "Leave Page")
        alert.addButton(withTitle: "Stay on Page")
        present(alert, in: window) { done($0 == .alertFirstButtonReturn) }
    }

    /// Always a sheet on its window. A dialog asked for while another is up
    /// follows it (AppKit queues sheets) instead of stopping the whole app
    /// with a loose alert on top of the first.
    private static func present(_ alert: NSAlert, in window: NSWindow?, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else { return done(alert.runModal()) }
        alert.beginSheetModal(for: window, completionHandler: done)
    }
}

// MARK: - Downloads

/// One file coming in, or come in.
@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var name: String
    @Published var url: URL?
    @Published var fraction: Double = 0
    @Published var finished = false
    @Published var failed = false
    weak var download: WKDownload?
    /// From a private window: off the list once those are all closed.
    let isPrivate: Bool

    init(download: WKDownload, isPrivate: Bool) {
        self.download = download
        self.isPrivate = isPrivate
        name = download.originalRequest?.url?.lastPathComponent ?? "Download"
    }

    var active: Bool { !finished && !failed }

    private var drawn: (url: URL?, finished: Bool, image: NSImage)?

    /// The file's icon, looked up when the file is named and again when it
    /// lands, not on every redraw of the row.
    var icon: NSImage {
        if let drawn, drawn.url == url, drawn.finished == finished { return drawn.image }
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .data)
        drawn = (url, finished, image)
        return image
    }

    /// Progress is read when the list asks for it, not pushed for every
    /// chunk that arrives: twenty downloads otherwise redraw the list
    /// hundreds of times a second, and cost the main thread even when the
    /// list is closed.
    func refresh() {
        guard active, let value = download?.progress.fractionCompleted, value != fraction else { return }
        fraction = value
    }

    func cancel() {
        let url = url
        if let download { download.cancel { _ in Downloads.discard(url) } } else { Downloads.discard(url) }
        failed = true
        Downloads.shared.cancelled(self)
    }
}

/// Files go straight to Downloads, under the name the site gives them, and
/// bounce the Downloads stack in the Dock when they land. The toolbar's
/// Downloads button lists them.
@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = Downloads()
    @Published private(set) var items: [DownloadItem] = []
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    private var watchers = 0
    private var ticker: Timer?

    /// The list is on screen (or gone again): progress bars only move while
    /// someone is looking, ten times a second, all rows in one pass.
    func watch(_ watching: Bool) {
        watchers = max(0, watchers + (watching ? 1 : -1))
        retime()
    }

    private func retime() {
        let wanted = watchers > 0 && items.contains { $0.active }
        if wanted, ticker == nil {
            items.forEach { $0.refresh() }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.items.forEach { $0.refresh() }
                    self.retime()
                }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !wanted, ticker != nil {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func track(_ download: WKDownload, in window: NSWindow?) {
        download.delegate = self
        windows[ObjectIdentifier(download)] = window
        let isPrivate = (window?.windowController as? BrowserWindowController)?.isPrivate == true
        items.insert(DownloadItem(download: download, isPrivate: isPrivate), at: 0)
        if items.count > 30 { items.removeLast() }
        retime()
    }

    func clear() {
        items.removeAll { $0.finished || $0.failed }
    }

    /// The last private window closed: what it downloaded, done or stopped,
    /// leaves the list with it. The files stay where they were saved.
    func forgetPrivate() {
        items.removeAll { $0.isPrivate && !$0.active }
    }

    /// Quitting stops what was still coming down; the half files go too.
    func discardUnfinished() {
        for item in items where item.active {
            if let url = item.url { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// A download that stopped part-way leaves no half file under its real name.
    nonisolated static func discard(_ url: URL?) {
        guard let url else { return }
        // On the naming queue, and the name freed only after: a new download
        // can't be given this name and then lose its file to this removal.
        naming.async {
            try? FileManager.default.removeItem(at: url)
            promised.remove(url.path.lowercased())
        }
    }

    /// Names are picked one at a time, off the main thread: the first look
    /// into Downloads can wait on the system asking for permission, and the
    /// window must not hang (or lose ⌘W) while it does.
    private nonisolated static let naming = DispatchQueue(label: "sill.downloads.naming", qos: .userInitiated)
    /// Names given out to downloads that haven't written a byte yet, in
    /// lower case: Downloads usually doesn't tell "A.pdf" from "a.pdf".
    private nonisolated(unsafe) static var promised: Set<String> = []

    /// A free name in Downloads, or nil if Sill isn't allowed in there.
    private nonisolated static func destination(named name: String) -> URL? {
        let files = FileManager.default
        let folder = files.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard (try? files.contentsOfDirectory(atPath: folder.path)) != nil else { return nil }
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while files.fileExists(atPath: url.path) || promised.contains(url.path.lowercased()) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        promised.insert(url.path.lowercased())
        return url
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        nonisolated(unsafe) let completionHandler = completionHandler
        Self.naming.async {
            let url = Self.destination(named: name)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let window = self.windows[ObjectIdentifier(download)]
                    let browser = window?.windowController as? BrowserWindowController
                    guard let url else {
                        // No way into Downloads: stopped, and said so, rather
                        // than a row that sits at nothing for good.
                        self.windows[ObjectIdentifier(download)] = nil
                        let item = self.item(for: download)
                        item?.failed = true
                        self.settled(item)
                        completionHandler(nil)
                        browser?.toast("Download failed: Sill isn’t allowed to save to Downloads")
                        return
                    }
                    if let item = self.item(for: download) {
                        item.name = url.lastPathComponent
                        item.url = url
                        // Cancelled while its name was being picked.
                        if item.failed { Self.naming.async { Self.promised.remove(url.path.lowercased()) }; return completionHandler(nil) }
                    }
                    completionHandler(url)
                    browser?.toast("Downloading “\(url.lastPathComponent)”")
                }
            }
        }
    }

    /// A cancelled download reports nothing more: its name is free again.
    func cancelled(_ item: DownloadItem) {
        if let download = item.download { windows[ObjectIdentifier(download)] = nil }
        settled(item, freesName: false)
    }

    private func settled(_ item: DownloadItem?, freesName: Bool = true) {
        if freesName, let path = item?.url?.path { Self.naming.async { Self.promised.remove(path.lowercased()) } }
        if let item, item.isPrivate, !AppDelegate.shared.browsers.contains(where: { $0.isPrivate }) {
            items.removeAll { $0 === item }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let window = windows.removeValue(forKey: ObjectIdentifier(download))
        guard let item = item(for: download), let url = item.url else { return }
        item.finished = true
        item.fraction = 1
        settled(item)
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        (window?.windowController as? BrowserWindowController)?.toast("Downloaded “\(url.lastPathComponent)”",
                                                                    action: ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let window = windows.removeValue(forKey: ObjectIdentifier(download))
        let item = item(for: download)
        item?.failed = true
        Self.discard(item?.url)
        settled(item)
        if (error as NSError).code != NSURLErrorCancelled {
            (window?.windowController as? BrowserWindowController)?.toast("Download failed: \(error.localizedDescription)")
        }
    }
}

/// The toolbar's Downloads list: a plain native list in the system popover.
struct DownloadsView: View {
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if downloads.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No Downloads").font(.headline)
                    Text("Files you download appear here.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(downloads.items) { DownloadRow(item: $0) }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)
                Divider()
                HStack {
                    Button("Clear") { downloads.clear() }
                        .disabled(!downloads.items.contains { $0.finished || $0.failed })
                    Spacer()
                    Button("Open Downloads Folder") {
                        NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                    }
                }
                .controlSize(.small)
                .padding(10)
            }
        }
        .frame(width: 340)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if item.failed {
                    Text("Stopped").font(.caption).foregroundStyle(.secondary)
                } else if item.finished {
                    Text("Done").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView(value: item.fraction).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if item.finished, let url = item.url {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            } else if !item.failed {
                Button { item.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Stop")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if item.finished, let url = item.url { NSWorkspace.shared.open(url) } }
    }
}
