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
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return done(nil) }
            done(URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
        }
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
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
    private var watching: NSKeyValueObservation?

    init(download: WKDownload) {
        self.download = download
        name = download.originalRequest?.url?.lastPathComponent ?? "Download"
        watching = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            DispatchQueue.main.async { self?.fraction = value }
        }
    }

    func cancel() {
        download?.cancel { _ in }
        failed = true
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

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func track(_ download: WKDownload, in window: NSWindow?) {
        download.delegate = self
        windows[ObjectIdentifier(download)] = window
        items.insert(DownloadItem(download: download), at: 0)
        if items.count > 30 { items.removeLast() }
    }

    func clear() {
        items.removeAll { $0.finished || $0.failed }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        if let item = item(for: download) {
            item.name = url.lastPathComponent
            item.url = url
        }
        completionHandler(url)
        let window = windows[ObjectIdentifier(download)]
        (window?.windowController as? BrowserWindowController)?.toast("Downloading “\(url.lastPathComponent)”")
    }

    func downloadDidFinish(_ download: WKDownload) {
        let window = windows.removeValue(forKey: ObjectIdentifier(download))
        guard let item = item(for: download), let url = item.url else { return }
        item.finished = true
        item.fraction = 1
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        (window?.windowController as? BrowserWindowController)?.toast("Downloaded “\(url.lastPathComponent)”",
                                                                    action: ("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let window = windows.removeValue(forKey: ObjectIdentifier(download))
        item(for: download)?.failed = true
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
            Image(nsImage: item.url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .data))
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
