import AppKit
import SwiftUI
import UniformTypeIdentifiers
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

    /// `closing`: the page's title, when it is asked because its tab, its
    /// window or Sill is closing; its page may not have drawn behind the sheet.
    static func leave(closing title: String? = nil, in window: NSWindow?, _ done: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title.map { "Are you sure you want to leave “\($0)”?" } ?? "Are you sure you want to leave this page?"
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
    /// Chromium's downloads: the page that started it (which stops it), and
    /// how far it had got when it last said.
    /// Held while the download runs: a page let go (its tab closed or put
    /// to sleep) took the download's updates and its Stop with it.
    var engineView: SEWebView?
    var reported: Double = 0
    /// From a private window: off the list once those are all closed.
    let isPrivate: Bool

    init(download: WKDownload, isPrivate: Bool) {
        self.download = download
        self.isPrivate = isPrivate
        name = download.originalRequest?.url?.lastPathComponent ?? "Download"
    }

    init(file: URL, from view: SEWebView, isPrivate: Bool) {
        engineView = view
        self.isPrivate = isPrivate
        name = file.lastPathComponent
        url = file
    }

    var active: Bool { !finished && !failed }
    /// When it began: what the time left is reckoned from.
    let began = Date()

    /// "1.2 MB · PDF document", read once when it lands, not on every redraw.
    private(set) lazy var detail: String = {
        guard let url else { return "" }
        let kind = UTType(filenameExtension: url.pathExtension)?.localizedDescription
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [size, kind].compactMap { $0 }.joined(separator: " · ")
    }()

    /// Still where it landed: moved or thrown away since, it can't be opened or dragged.
    var isThere: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// "45% · About 12 seconds left": time left only once there's enough to go on.
    var status: String {
        guard fraction > 0 else { return "Starting…" }
        let percent = "\(Int((fraction * 100).rounded(.down)))%"
        let elapsed = Date().timeIntervalSince(began)
        guard fraction > 0.03, fraction < 1, elapsed > 2 else { return percent }
        var left = elapsed * (1 - fraction) / fraction
        if left > 10 { left = (left / 5).rounded() * 5 }
        let format = DateComponentsFormatter()
        format.unitsStyle = .full
        format.maximumUnitCount = 1
        format.allowedUnits = left >= 3600 ? [.hour, .minute] : left >= 60 ? [.minute] : [.second]
        guard let words = format.string(from: max(1, left)) else { return percent }
        return "\(percent) · About \(words) left"
    }

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
        guard active else { return }
        let value = download?.progress.fractionCompleted ?? reported
        guard value != fraction else { return }
        fraction = value
    }

    func cancel() {
        let url = url
        if let download {
            download.cancel { _ in Downloads.discard(url) }
        } else if let engineView, let url {
            // Chromium takes its half file away itself.
            engineView.cancelDownload(to: url)
        } else {
            Downloads.discard(url)
        }
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
    private var tickEvery: TimeInterval = 0

    /// How everything still coming down is going, for the toolbar's ring and
    /// the Dock. `fraction` is nil when some file's size isn't known.
    struct Overall: Equatable {
        var count: Int
        var fraction: Double?
    }
    /// Said whenever `overall(isPrivate:)` changes.
    static let progressChanged = Notification.Name("SillDownloadsProgress")
    private var lastOverall: [Bool: Overall?] = [:]

    func overall(isPrivate: Bool) -> Overall? {
        let running = items.filter { $0.active && $0.isPrivate == isPrivate }
        guard !running.isEmpty else { return nil }
        let sizes = running.map(\.fraction)
        // Whole percents: the ring moves when it can be seen to, not more often.
        let fraction = sizes.contains { $0 < 0 } ? nil : (sizes.reduce(0, +) / Double(sizes.count) * 100).rounded() / 100
        return Overall(count: running.count, fraction: fraction)
    }

    /// The list is on screen (or gone again): its rows move ten times a
    /// second while someone looks; otherwise four, for the ring alone.
    func watch(_ watching: Bool) {
        watchers = max(0, watchers + (watching ? 1 : -1))
        retime()
    }

    private func retime() {
        let wanted: TimeInterval = !items.contains { $0.active } ? 0 : watchers > 0 ? 0.1 : 0.25
        if wanted != tickEvery {
            ticker?.invalidate()
            ticker = nil
            tickEvery = wanted
            if wanted > 0 {
                tick()
                let timer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                timer.tolerance = wanted / 5
                RunLoop.main.add(timer, forMode: .common)
                ticker = timer
            }
        }
        announce()
    }

    private func tick() {
        items.forEach { $0.refresh() }
        announce()
    }

    /// Tells the windows (and the Dock) only when what they show would change.
    private func announce() {
        var moved = false
        for isPrivate in [false, true] {
            let now = overall(isPrivate: isPrivate)
            if lastOverall[isPrivate] != now { lastOverall[isPrivate] = now; moved = true }
        }
        guard moved else { return }
        NotificationCenter.default.post(name: Self.progressChanged, object: self)
        DockProgress.shared.show(overall(isPrivate: false), private: overall(isPrivate: true))
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func track(_ download: WKDownload, in window: NSWindow?) {
        download.delegate = self
        windows[ObjectIdentifier(download)] = window
        let isPrivate = (window?.windowController as? BrowserWindowController)?.isPrivate == true
        add(DownloadItem(download: download, isPrivate: isPrivate))
    }

    private func add(_ item: DownloadItem) {
        items.insert(item, at: 0)
        // The list keeps 30, oldest out first, but never drops one still
        // coming down: its row is what stops it and clears up after it.
        while items.count > 30, let old = items.lastIndex(where: { !$0.active }) { items.remove(at: old) }
        retime()
    }

    /// A download began: the Downloads list opens under its button, showing
    /// it, as Safari's does, in place of a toast. In the window it came from,
    /// or, from a popup (which has no button), the browser window behind it.
    static func reveal(in window: NSWindow?) {
        var browser = window?.windowController as? BrowserWindowController
        if browser?.isPopup != false {
            let isPrivate = browser?.isPrivate ?? false
            // The front-most such window, not the newest.
            let front = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserWindowController }
            browser = front.first { !$0.isPopup && $0.isPrivate == isPrivate }
        }
        browser?.revealDownloads()
    }

    /// Chromium began a download into `file`.
    func started(_ file: URL, from view: SEWebView, in window: NSWindow?, reveal: Bool = true) {
        let isPrivate = (window?.windowController as? BrowserWindowController)?.isPrivate == true
        add(DownloadItem(file: file, from: view, isPrivate: isPrivate))
        if reveal { Self.reveal(in: window) }
    }

    /// How Chromium's download into `file` is going. Progress is only noted
    /// here; the list reads it when it draws (refresh).
    func progressed(_ file: URL, from view: SEWebView, fraction: Double, done: Bool, failed: Bool) {
        guard let item = items.first(where: { $0.active && $0.url == file && $0.engineView === view }) else { return }
        item.reported = fraction
        guard done else { return }
        if failed {
            item.failed = true
        } else {
            item.finished = true
            item.fraction = 1
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
        let page = item.engineView
        item.engineView = nil
        settled(item, freesName: false)
        retime()
        closeIfDone(page)
    }

    /// Whether a page has a download still running (it isn't put to sleep).
    func isDownloading(in view: SEWebView) -> Bool {
        items.contains { $0.active && $0.engineView === view }
    }

    /// Pages whose tab closed while they downloaded: they hear on behalf
    /// of the tab, and close once their downloads are all done.
    private var orphans: [ObjectIdentifier: SEWebView] = [:]
    private lazy var relay = Relay(downloads: self)

    func outlive(_ view: SEWebView) {
        view.pageDelegate = relay
        orphans[ObjectIdentifier(view)] = view
    }

    private func closeIfDone(_ view: SEWebView?) {
        guard let view, orphans[ObjectIdentifier(view)] != nil, !isDownloading(in: view) else { return }
        orphans[ObjectIdentifier(view)] = nil
        view.closePage()
    }

    private final class Relay: NSObject, SEWebViewDelegate {
        weak var downloads: Downloads?
        init(downloads: Downloads) { self.downloads = downloads }
        func webView(_ view: SEWebView, download file: URL, progress: Double, done: Bool, failed: Bool) {
            MainActor.assumeIsolated {
                downloads?.progressed(file, from: view, fraction: progress, done: done, failed: failed)
            }
        }
    }

    func clear(isPrivate: Bool) {
        items.removeAll { $0.isPrivate == isPrivate && ($0.finished || $0.failed) }
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
                    Self.reveal(in: window)
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
        // The list's Clear depends on rows being done, which it isn't told of
        // by the rows themselves.
        objectWillChange.send()
        defer { retime() }
        if freesName, let path = item?.url?.path { Self.naming.async { Self.promised.remove(path.lowercased()) } }
        if let item, item.isPrivate, !AppDelegate.shared.browsers.contains(where: { $0.isPrivate }) {
            items.removeAll { $0 === item }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        windows[ObjectIdentifier(download)] = nil
        guard let item = item(for: download), let url = item.url else { return }
        item.finished = true
        item.fraction = 1
        settled(item)
        // Done in the list (its row says so); the Dock's Downloads stack bounces.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
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
/// A panel's backing in dark mode: the system's popover glass turns pale
/// over a white page, and white text (and a selected segment) on it can't
/// be read. A dark layer under the contents keeps them legible; light mode
/// is left to the glass.
struct PanelBacking: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(scheme == .dark ? Color.black.opacity(0.5) : Color.clear)
    }
}

struct DownloadsView: View {
    @ObservedObject private var downloads = Downloads.shared
    /// A private window lists its own downloads; others never see them.
    var isPrivate = false
    private var items: [DownloadItem] { downloads.items.filter { $0.isPrivate == isPrivate } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No Downloads").font(.headline)
                    Text("Files you download appear here.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                // Safari's arrangement, one line: what this is, and Clear.
                HStack {
                    Text("Downloads").font(.headline)
                    Spacer()
                    Button("Clear") { withAnimation(Motion.snappy) { downloads.clear(isPrivate: isPrivate) } }
                        .buttonStyle(.borderless)
                        .disabled(!items.contains { !$0.active })
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items) { item in
                            DownloadRow(item: item)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 320)
        .animation(Motion.snappy, value: items.map(\.id))
    }
}

/// One file: click to open it, drag it out to put a copy wherever it's let
/// go (the Desktop, a folder, a mail, a page's upload), as Safari's list does.
private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @State private var hovering = false

    private var openable: URL? { item.finished && item.isThere ? item.url : nil }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .opacity(item.finished && !item.isThere ? 0.5 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.active {
                        // Size unknown (no length from the server): it moves, not fills.
                        if item.fraction < 0 { ProgressView().progressViewStyle(.linear).controlSize(.mini) }
                        else { ProgressView(value: item.fraction).controlSize(.mini) }
                        Text(item.fraction < 0 ? "Downloading…" : item.status)
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(FileDragArea(url: openable, icon: item.icon) { if let url = openable { NSWorkspace.shared.open(url) } })

            if item.active {
                Button { item.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop")
                    .accessibilityLabel("Stop")
            } else if let url = openable {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(hovering && openable != nil ? Color.primary.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Open") { if let url = openable { NSWorkspace.shared.open(url) } }
    }

    private var subtitle: String {
        if item.failed { return "Stopped" }
        if !item.isThere { return "Moved or deleted" }
        return item.detail.isEmpty ? "Done" : item.detail
    }
}

/// Under a downloaded file's row: a click opens it, a drag carries the file
/// out. A copy, never a move: the file stays in Downloads, and on the list.
private struct FileDragArea: NSViewRepresentable {
    let url: URL?
    let icon: NSImage
    let open: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {
        view.url = url
        view.icon = icon
        view.open = open
    }

    final class DragView: NSView, NSDraggingSource {
        var url: URL?
        var icon: NSImage?
        var open: (() -> Void)?
        private var downAt: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

        override func mouseDragged(with event: NSEvent) {
            guard let start = downAt, let url else { return }
            let at = event.locationInWindow
            guard hypot(at.x - start.x, at.y - start.y) > 3 else { return }
            downAt = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let point = convert(start, from: nil)
            item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if downAt != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { open?() }
            downAt = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }
}

extension Motion {
    /// The list's rows coming and going: none with Reduce Motion.
    static var snappy: Animation? { reduced ? nil : .snappy(duration: standard) }
}

/// The Dock icon while files come down: a small round badge at its corner
/// with how many, ringed by how far along they are, as Dia's. Gone the
/// moment the last one lands, leaving the system's own icon.
@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private var view: BadgeView?

    func show(_ yours: Downloads.Overall?, private secret: Downloads.Overall?) {
        // Private downloads count, but say nothing more than a number would.
        let count = (yours?.count ?? 0) + (secret?.count ?? 0)
        let tile = NSApp.dockTile
        guard count > 0 else {
            guard view != nil else { return }
            view = nil
            tile.contentView = nil
            tile.display()
            return
        }
        let parts = [yours, secret].compactMap { $0 }
        let fraction: Double? = parts.contains { $0.fraction == nil } ? nil
            : parts.reduce(0) { $0 + ($1.fraction ?? 0) * Double($1.count) } / Double(count)
        if view == nil {
            let badge = BadgeView(frame: NSRect(origin: .zero, size: tile.size))
            view = badge
            tile.contentView = badge
        }
        guard let view, view.count != count || view.fraction != fraction else { return }
        view.count = count
        view.fraction = fraction
        tile.display()
    }

    private final class BadgeView: NSView {
        var count = 0
        var fraction: Double?

        override func draw(_ dirtyRect: NSRect) {
            NSApp.applicationIconImage?.draw(in: bounds)
            let side = bounds.width * 0.36
            let inset = bounds.width * 0.06
            let disc = NSRect(x: bounds.maxX - side - inset, y: bounds.minY + inset, width: side, height: side)
            NSShadow.withShadow(blur: side * 0.12, offset: -side * 0.03) {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: disc).fill()
            }
            let line = side * 0.1
            let ring = disc.insetBy(dx: line * 0.9, dy: line * 0.9)
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = line
            NSColor(white: 0, alpha: 0.1).setStroke()
            track.stroke()
            let center = NSPoint(x: ring.midX, y: ring.midY)
            let arc = NSBezierPath()
            // Unknown size: a quarter of the ring, standing for "on its way".
            let along = fraction.map { max(0.02, min(1, $0)) } ?? 0.25
            arc.appendArc(withCenter: center, radius: ring.width / 2, startAngle: 90, endAngle: 90 - 360 * along, clockwise: true)
            arc.lineWidth = line
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.usingColorSpace(.displayP3)?.setStroke()
            arc.stroke()
            let text = count > 99 ? "99+" : "\(count)"
            let font = NSFont.systemFont(ofSize: side * (text.count > 1 ? 0.36 : 0.44), weight: .semibold)
            let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.2, alpha: 1)])
            let size = label.size()
            label.draw(at: NSPoint(x: disc.midX - size.width / 2, y: disc.midY - size.height / 2))
        }
    }
}

private extension NSShadow {
    static func withShadow(blur: CGFloat, offset: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: offset)
        shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }
}
