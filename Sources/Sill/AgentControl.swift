import AppKit
import WebKit

// Agents on this Mac — Claude Code, Codex, a script — driving Sill, when you
// let them (Settings › Agents, off until you turn it on).
//
// Sill listens on a Unix socket, agent.sock in its own Application Support
// folder: the folder this user's alone (0700), the socket 0600, and every
// connection's other end checked to be this same user before a byte is read.
// Never on the network itself: claude.ai reaches it through your relay, by
// way of Sill's own helper (Connector.swift). `sill-mcp`, inside the app, is the MCP server an
// agent runs; it speaks to this socket. The design follows Search's
// AgentControl (MIT, see NOTICE).
//
// The protocol is one JSON object per line each way:
//   → {"id": 1, "cmd": "tabs.open", "args": {"url": "https://example.com"}}
//   ← {"id": 1, "ok": true, "result": {...}}  or  {"id": 1, "ok": false, "error": "..."}
// AGENTS.md lists every command.
//
// What an agent never gets: private windows, the values of password fields,
// Sill's own settings, files, or anything but http and https to navigate to.

@MainActor
final class AgentServer {
    static let shared = AgentServer()

    static var socketURL: URL { Places.support.appendingPathComponent("agent.sock") }

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: AgentConnection] = [:]
    private let queue = DispatchQueue(label: "app.sill.agent")
    private(set) var connected = 0
    private var watching: Any?

    /// Starts or stops with the setting.
    func follow(_ prefs: Preferences) {
        watching = prefs.$agentControl.sink { [weak self] on in
            DispatchQueue.main.async { on ? self?.start() : self?.stop() }
        }
    }

    func start() {
        guard listener < 0 else { return }
        let path = Self.socketURL.path
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Places.support.path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else { close(fd); return }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            // Only this user: anyone else's process is turned away unheard.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); return }
            DispatchQueue.main.async { self?.adopt(client) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listener = -1
        connections.values.forEach { $0.close() }
        connections = [:]
        connected = 0
        unlink(Self.socketURL.path)
    }

    private func adopt(_ fd: Int32) {
        let connection = AgentConnection(fd: fd, queue: queue)
        let key = ObjectIdentifier(connection)
        connection.onEnd = { [weak self] in
            self?.connections[key] = nil
            self?.connected = self?.connections.count ?? 0
        }
        connections[key] = connection
        connected = connections.count
        connection.start()
        if connected == 1 { AppDelegate.shared.current?.toast("An agent connected to Sill") }
    }
}

/// One client: lines in, answers out, in order.
@MainActor
final class AgentConnection {
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    var onEnd: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    func start() {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let fd = self.fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            let data = count > 0 ? Data(chunk[0..<count]) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                if let data { self.take(data) } else { self.close() }
            }
        }
        source.resume()
        self.source = source
    }

    func close() {
        guard let source else { return }
        self.source = nil
        source.cancel()
        Darwin.close(fd)
        // The agent's gone: the tabs it held are yours again.
        AgentActivity.shared.releaseAll(owner: ObjectIdentifier(self))
        onEnd?()
    }

    private func take(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                send(["ok": false, "error": "Not a JSON object."])
                continue
            }
            let id = request["id"]
            let owner = ObjectIdentifier(self)
            Task { @MainActor in
                // Tabs this command touches are held by this connection until it's released or closed.
                var answer = await AgentCommands.$owner.withValue(owner) { await AgentCommands.run(request) }
                answer["id"] = id ?? NSNull()
                self.send(answer)
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard source != nil,
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]) else { return }
        data.append(0x0A)
        let fd = self.fd
        queue.async {
            data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 { break }
                    sent += n
                }
            }
        }
    }
}

// MARK: - Commands

struct AgentError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor
enum AgentCommands {
    /// The connection a command came on (set around each command), so the tabs it touches are tied to it.
    @TaskLocal static var owner: ObjectIdentifier?

    static func run(_ request: [String: Any]) async -> [String: Any] {
        guard Preferences.shared.agentControl else { return ["ok": false, "error": "Agent control is off in Sill's settings."] }
        let command = request["cmd"] as? String ?? ""
        let args = request["args"] as? [String: Any] ?? [:]
        AgentActivity.shared.began()
        // Whatever the agent does in its hidden tabs, the keyboard stays where you left it.
        let keyboard = Self.keyboards()
        defer {
            AgentActivity.shared.ended()
            Self.giveBack(keyboard)
        }
        let session = args["_session"] as? String ?? (args["_via"] as? String).map { "via:" + $0 } ?? owner.map { "\($0.hashValue)" } ?? "local"
        do {
            let result = try await Self.$session.withValue(session) { try await bounded(command, args) }
            AgentLog.record(command: command, args: args, result: result, error: nil)
            return ["ok": true, "result": result]
        } catch let error as AgentError {
            AgentLog.record(command: command, args: args, result: nil, error: error.message)
            return ["ok": false, "error": error.message]
        } catch {
            AgentLog.record(command: command, args: args, result: nil, error: error.localizedDescription)
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    // MARK: your keyboard

    /// Each window's first responder, before an agent command.
    private static func keyboards() -> [(NSWindow, NSResponder?)] {
        AppDelegate.shared.browsers.compactMap { $0.window.map { ($0, $0.firstResponder) } }
    }

    /// The page an agent clicked or focused in its hidden tab may have taken the
    /// keyboard (Chromium focuses a page on input): handed back to what had it.
    private static func giveBack(_ before: [(NSWindow, NSResponder?)]) {
        for (window, previous) in before {
            guard let now = window.firstResponder as? NSView, now !== previous,
                  let page = sequence(first: now, next: { $0.superview }).first(where: { $0 is SillWebView }) as? SillWebView,
                  page.agentAtWork, page.tab.map({ t in !browsers.contains { $0.selected === t } }) ?? true else { continue }
            if let previous = previous as? NSView, previous.window === window { window.makeFirstResponder(previous) }
            else if let front = AppDelegate.shared.browsers.first(where: { $0.window === window })?.selected?.webView { window.makeFirstResponder(front) }
            else { window.makeFirstResponder(nil) }
        }
    }

    /// Who has the keyboard in the front window: the tab in front, an agent's hidden tab, or something else.
    private static var keyboardOwner: String {
        guard let window = AppDelegate.shared.current?.window, let view = window.firstResponder as? NSView else { return "none" }
        guard let page = sequence(first: view, next: { $0.superview }).first(where: { $0 is SillWebView }) as? SillWebView else { return "window" }
        if page.tab === AppDelegate.shared.current?.selected { return "front tab" }
        return page.agentAtWork ? "agent tab" : "other tab"
    }

    // MARK: finding things

    /// Normal windows and the popups their pages open (sign-in windows), never private ones.
    private static var browsers: [BrowserWindowController] {
        AppDelegate.shared.browsers.filter { !$0.isPrivate }
    }

    /// A tab a page opened while the agent worked in it: the agent's too, in the background.
    /// The opener is the tab the agent acted in: only an action in that very tab hears of the new one, so
    /// agents working side by side never pick up each other's tabs. It becomes the agent's current tab when
    /// its action answers (in that agent's own session).
    static func adopt(_ tab: Tab, from opener: Tab) {
        tab.openedByAgent = true
        adoptedFrom[ObjectIdentifier(opener)] = (tab, Date())
    }
    private static var adoptedFrom: [ObjectIdentifier: (tab: Tab, at: Date)] = [:]

    /// Tabs the agent opened or named, the latest first. Leaving out "tab"
    /// means the latest of these still open, so an agent's work stays in its
    /// own tabs, out of sight, and never wanders into the one you're reading.
    /// Per agent: each client (a Claude Code session, claude.ai through the relay) has its
    /// own current tab, so agents working side by side never act in each other's tabs.
    private static var agentTabs: [WeakTab] {
        get { tabsBySession[session] ?? [] }
        set { tabsBySession[session] = newValue }
    }
    private static var tabsBySession: [String: [WeakTab]] = [:]
    /// The agent a command comes from: sill-mcp stamps "_session" (one per client); else its connection.
    @TaskLocal static var session: String = "local"

    private final class WeakTab {
        weak var tab: Tab?
        init(_ tab: Tab) { self.tab = tab }
    }

    private static func remember(_ tab: Tab) {
        agentTabs.removeAll { $0.tab == nil || $0.tab === tab }
        agentTabs.insert(WeakTab(tab), at: 0)
        if agentTabs.count > 32 { agentTabs.removeLast(agentTabs.count - 32) }
    }

    private static func browser(of tab: Tab) -> BrowserWindowController? {
        browsers.first { $0.tabs.contains { $0 === tab } }
    }

    private static func describe(_ tab: Tab, in browser: BrowserWindowController) -> [String: Any] {
        [
            "id": tab.id.uuidString,
            "window": browser.windowNumber,
            "url": (tab.webView?.url ?? tab.url)?.absoluteString ?? "",
            "title": tab.displayTitle,
            "loading": tab.isLoading,
            "selected": tab === browser.selected,
            "asleep": tab.webView == nil,
            "openedByAgent": tab.openedByAgent,
            "held": AgentActivity.shared.held.contains { $0 === tab },
            "loadError": tab.displayTitle == "Can’t open this page" ? (tab.failedWith ?? "Sill couldn’t open it.") as Any : NSNull(),
            "agentCurrent": agentTabs.first { $0.tab.map { Self.browser(of: $0) != nil } ?? false }?.tab === tab,
        ]
    }

    private static func tab(_ args: [String: Any]) throws -> (Tab, BrowserWindowController) {
        if let id = args["tab"] as? String {
            for browser in browsers {
                if let tab = browser.tabs.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) {
                    if args["remember"] as? Bool ?? true { remember(tab) }
                    return (tab, browser)
                }
            }
            throw AgentError("No tab with id \(id). Call tabs.list for current ids.")
        }
        for weak in agentTabs {
            if let tab = weak.tab, let browser = browser(of: tab) { return (tab, browser) }
        }
        // Never the tab you're in by default: an agent works only in tabs it opened or
        // was given by id (tabs.list), so its clicks and glow can't land on your page.
        throw AgentError("You have no tab of your own open. Open one with tabs_open, or name one of the user's by id (tabs_list).")
    }

    /// The tab's page, made if it was asleep, drawing even out of sight, and
    /// marked as the agent's work in progress.
    private static func webView(_ args: [String: Any]) async throws -> (SillWebView, Tab, BrowserWindowController) {
        let (tab, browser) = try tab(args)
        let view = tab.materialize()
        keepDrawing(view, of: tab, in: browser)
        AgentActivity.shared.touch(tab, view: view, in: browser)
        view.holdsDialogs = true
        await prepare(view)
        await AgentPage.of(view).start()
        return (view, tab, browser)
    }

    private static func onScreen(_ tab: Tab, in browser: BrowserWindowController) -> Bool {
        tab === browser.selected || browser.split?.contains(tab) == true
    }

    /// A page out of sight goes under the one in front, unhidden: Chromium
    /// draws it (screenshots need frames), and nobody sees it.
    private static func keepDrawing(_ view: SillWebView, of tab: Tab, in browser: BrowserWindowController) {
        guard !onScreen(tab, in: browser), let host = pageHost(of: browser) else { return }
        if host.subviews.first !== view {
            view.frame = browser.selected?.webView?.frame ?? host.bounds
            host.addSubview(view, positioned: .below, relativeTo: nil)
        }
        view.agentAtWork = true
        // Drawn in the window but not yours: a load there never takes the keys.
        view.takesFocusOnLoad = false
        if view.pageHidden { view.insistShown() }
    }

    /// Put aside again once the agent has left it alone a while.
    /// An agent's tab it left behind, a while after its last touch: closed, so an agent never
    /// spends a turn tidying up. Not one you've looked at, one it handed you, or half of a split.
    static func tidy(_ tab: Tab) {
        guard tab.openedByAgent, !tab.keptForUser, tab.seenAt == nil, let browser = browser(of: tab),
              browser.split?.contains(tab) != true, browser.selected !== tab, browser.tabs.count > 1 else { return }
        for key in Array(tabsBySession.keys) { tabsBySession[key]?.removeAll { $0.tab == nil || $0.tab === tab } }
        browser.closeNow(tab)
    }

    static func letGo(_ view: SillWebView, of tab: Tab) {
        if view.openDialog == nil { view.holdsDialogs = false }
        // Focus emulation keeps Chromium counting the page as captured, and a
        // captured page is "visible" even hidden: it went on drawing at 60
        // frames a second out of sight, for good (measured). Off with the agent.
        if prepared.remove(ObjectIdentifier(view)) != nil {
            Task { @MainActor in _ = try? await devtools(view, "Emulation.setFocusEmulationEnabled", ["enabled": false], timeout: 3) }
        }
        guard view.agentAtWork else { return }
        view.agentAtWork = false
        view.takesFocusOnLoad = !view.drawingAhead
        if let browser = browser(of: tab), onScreen(tab, in: browser) { return }
        view.park()
    }

    private static func pageHost(of browser: BrowserWindowController) -> NSView? {
        if let host = browser.selected?.webView?.superview as? PageHostView { return host }
        func search(_ view: NSView) -> NSView? {
            if view is PageHostView { return view }
            for child in view.subviews { if let found = search(child) { return found } }
            return nil
        }
        return browser.window?.contentView.flatMap(search)
    }

    /// Once per page: it believes it has focus, so keys and typing land
    /// though Sill's window isn't the key one.
    private static var prepared = Set<ObjectIdentifier>()
    private static func prepare(_ view: SillWebView) async {
        let key = ObjectIdentifier(view)
        guard !prepared.contains(key) else { return }
        prepared.insert(key)
        _ = try? await devtools(view, "Emulation.setFocusEmulationEnabled", ["enabled": true], timeout: 3)
    }

    /// A file in Desktop, Documents, Downloads, Pictures, Movies or Music, and not hidden.
    /// Where your own files are: what agents may find, read and upload without asking.
    nonisolated static var everydayFolders: [String] {
        let home = NSHomeDirectory()
        // A test copy also has a folder of its own (macOS asks before an app reads Downloads and the like).
        let test = Places.testProfile.map { [NSTemporaryDirectory() + "sill-\($0)-files"] } ?? []
        return (["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                 "Library/Mobile Documents/com~apple~CloudDocs"].map { home + "/" + $0 } + test)
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func everyday(_ path: String) -> Bool {
        let real = (path as NSString).resolvingSymlinksInPath
        let folders = everydayFolders.map { (($0 as NSString).resolvingSymlinksInPath) + "/" }
        guard let folder = folders.first(where: { real.hasPrefix($0) }) else { return false }
        return !real.dropFirst(folder.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }

    private static func webURL(_ text: Any?) throws -> URL {
        guard let text = text as? String, !text.isEmpty else { throw AgentError("Missing \"url\".") }
        guard let url = Address.url(from: text) ?? URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AgentError("Only http and https addresses can be opened: \(text)")
        }
        return url
    }

    // MARK: the commands

    /// Every command answers within its limit, whatever the page does: a click on a page that never
    /// finishes loading answers with where things stand, not after minutes. (The work isn't undone.)
    private static func bounded(_ command: String, _ args: [String: Any]) async throws -> Any {
        let asked = args["timeout"] as? Double
        let limit: Double?
        switch command {
        case "connector.approve", "user.wait", "page.upload": limit = nil   // waits on you
        case "tabs.open", "page.navigate", "page.back", "page.forward", "page.reload", "page.wait": limit = (asked ?? 20) + 5
        case "page.eval": limit = 35
        case "files.find", "files.read", "page.screenshot": limit = 25
        default: limit = 15
        }
        guard let limit else { return try await perform(command, args) }
        final class Once { var done = false }
        let once = Once()
        let session = Self.session
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Any, Error>) in
            Task { @MainActor in
                do {
                    let r = try await Self.$session.withValue(session) { try await perform(command, args) }
                    if !once.done { once.done = true; c.resume(returning: r) }
                } catch {
                    if !once.done { once.done = true; c.resume(throwing: error) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
                guard !once.done else { return }
                once.done = true
                c.resume(throwing: AgentError("Still going after \(Int(limit)) s: the page hasn't answered (it may be loading something slow). Look again (page_read) before acting; don't repeat it blindly."))
            }
        }
    }

    /// Secrets Sill filled into each tab: wherever the page echoes one back, an agent sees "(from the vault)".
    private static var secretsShown: [ObjectIdentifier: Set<String>] = [:]
    private static func scrub(_ value: Any, for tab: Tab) -> Any {
        guard let secrets = secretsShown[ObjectIdentifier(tab)], !secrets.isEmpty else { return value }
        func clean(_ v: Any) -> Any {
            if let s = v as? String { return secrets.reduce(s) { $0.replacingOccurrences(of: $1, with: "(from the vault)") } }
            if let a = v as? [Any] { return a.map(clean) }
            if let d = v as? [String: Any] { return d.mapValues(clean) }
            return v
        }
        return clean(value)
    }

    private static func perform(_ command: String, _ args: [String: Any]) async throws -> Any {
        let result = try await performRaw(command, args)
        // Reads of a page go back with any vault secret it shows replaced.
        if ["page.snapshot", "page.text", "page.eval", "page.records"].contains(command), !secretsShown.isEmpty,
           let (tab, _) = try? tab(args.merging(["remember": false]) { $1 }) {
            return scrub(result, for: tab)
        }
        return result
    }

    private static func performRaw(_ command: String, _ args: [String: Any]) async throws -> Any {
        switch command {
        case "status":
            return ["app": "Sill", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    "windows": browsers.count, "tabs": browsers.reduce(0) { $0 + $1.tabs.count }, "keyboard": keyboardOwner]

        case "tabs.list":
            return browsers.flatMap { browser in browser.tabs.map { describe($0, in: browser) } }

        case "tabs.open":
            let url = try webURL(args["url"])
            // In the background unless asked: the tab appears, you stay where you are.
            let background = args["background"] as? Bool ?? true
            let existing = AppDelegate.shared.current.flatMap({ $0.isPrivate ? nil : $0 }) ?? browsers.last
            let browser = existing ?? AppDelegate.shared.makeBrowser(isPrivate: false)
            if existing == nil || !background { browser.showWindow(nil) }
            let tab = browser.addTab(url: url, select: !background)
            tab.openedByAgent = true
            tab.keptForUser = !background
            if args["remember"] as? Bool ?? true { remember(tab) }
            let view = tab.materialize()
            keepDrawing(view, of: tab, in: browser)
            AgentActivity.shared.touch(tab, view: view, in: browser)
            await prepare(view)
            if args["wait"] as? Bool ?? true {
                try await waitForReadable(tab, timeout: args["timeout"] as? Double ?? 20)
                // A check page that sends you on (a bot check, a locale redirect) isn't the page: settle past it.
                await settle(tab, view)
            }
            return describe(tab, in: browser)

        case "vault.list":
            // What the vault holds for this page's site (or all of it): names and kinds, never values.
            let host = (args["host"] as? String) ?? (try? tab(args.merging(["remember": false]) { $1 }).0.webView?.url?.host())
            return ["entries": AgentVault.list(for: args["all"] as? Bool == true ? nil : host)]

        case "vault.fill":
            // A secret typed into a field by Sill, never shown to the agent, and only on its own sites.
            guard let name = args["name"] as? String, let entry = AgentVault.entry(name) else { throw AgentError("Nothing called that in the vault (vault names: ask for the site's list).") }
            let (view, tab, _) = try await webView(args)
            guard let host = view.url?.host(), AgentVault.allowed(entry, on: host) else {
                throw AgentError("“\(entry.name)” is only for \(entry.sites.isEmpty ? "Sill itself" : entry.sites.joined(separator: ", ")): not filled here.")
            }
            var lookup: [String: Any] = ["editable": true]
            for (key, from) in [("ref", "ref"), ("selector", "selector"), ("text", "label")] { if let v = args[from] { lookup[key] = v } }
            let target = try await locate(lookup, in: view)
            let started = Date()
            _ = try? await evaluate("return window.__sillAgent.markVaulted(ref)", in: view, world: Web.world, arguments: ["ref": target.ref])
            let typed = try await type(entry.value, into: target, clear: true, in: view)
            if let into = typed.into { _ = try? await evaluate("return window.__sillAgent.markVaulted(ref)", in: view, world: Web.world, arguments: ["ref": into]) }
            if entry.value.count >= 4 { secretsShown[ObjectIdentifier(tab), default: []].insert(entry.value) }
            await settle(tab, view, since: started)
            return ["filled": typed.ok, "name": entry.name, "ref": typed.into ?? target.ref]

        case "vault.key":
            // A key for Sill's own helpers (TypeSafe's for page_goal): to this Mac's helpers only, never claude.ai's calls.
            guard args["_via"] == nil, let name = args["name"] as? String, let entry = AgentVault.entry(name), entry.kind == "service" else {
                throw AgentError("Not available.")
            }
            return ["value": entry.value]

        case "vault.set":
            guard args["_via"] == nil, let name = args["name"] as? String, !name.isEmpty, let value = args["value"] as? String, !value.isEmpty else {
                throw AgentError("Only from this Mac, with a name and a value.")
            }
            AgentVault.set(AgentVault.Entry(name: name, kind: args["kind"] as? String ?? "password", value: value,
                                  sites: args["sites"] as? [String] ?? [], user: args["user"] as? String))
            return ["saved": name]

        case "clipboard.set":
            // The agent's own clipboard (yours is never touched): what its next ⌘V pastes.
            guard let text = args["text"] as? String else { throw AgentError("Give \"text\".") }
            AgentClipboard.set(text: text, html: args["html"] as? String)
            return ["set": text.count]

        case "agent.stopped":
            // The client stopped the agent (claude.ai's stop button, a cancelled call): lights out.
            AgentActivity.shared.quiet()
            return ["quiet": true]

        case "tabs.release":
            // The agent is done with it: the tab is yours again (dots and glow go).
            if args["all"] as? Bool == true {
                let tabs = AgentActivity.shared.held
                tabs.forEach { $0.keptForUser = true; AgentActivity.shared.release($0) }
                agentTabs.removeAll()
                return ["released": tabs.count]
            }
            let (tab, _) = try tab(args)
            tab.keptForUser = true
            AgentActivity.shared.release(tab)
            agentTabs.removeAll { $0.tab == nil || $0.tab === tab }
            return ["released": 1]

        case "tabs.select":
            let (tab, browser) = try tab(args)
            tab.keptForUser = true
            browser.select(tab)
            browser.window?.makeKeyAndOrderFront(nil)
            return describe(tab, in: browser)

        case "tabs.close":
            let (tab, browser) = try tab(args)
            agentTabs.removeAll { $0.tab == nil || $0.tab === tab }
            AgentActivity.shared.forget(tab)
            // Never the last of your windows: closing its last tab would close
            // the window, and with no window left, utilities like Swift Quit
            // quit Sill outright. A fresh empty tab takes its place instead.
            let normalWindows = AppDelegate.shared.browsers.filter { !$0.isPrivate && !$0.isPopup && $0.window?.isVisible == true }
            if browser.tabs.count == 1, !browser.isPopup, normalWindows.count <= 1 {
                _ = browser.addTab(url: nil, select: true)
            }
            // An agent's close is its own decision: the page isn't asked.
            browser.closeNow(tab)
            return ["closed": tab.id.uuidString]

        case "page.navigate":
            let url = try webURL(args["url"])
            let (_, tab, browser) = try await webView(args)
            tab.load(url)
            if args["wait"] as? Bool ?? true {
                try await waitForReadable(tab, timeout: args["timeout"] as? Double ?? 20)
                await settle(tab, tab.materialize())
            }
            return describe(tab, in: browser)

        case "page.back", "page.forward", "page.reload", "page.stop":
            let (_, tab, browser) = try await webView(args)
            switch command {
            case "page.back": tab.goBack()
            case "page.forward": tab.goForward()
            case "page.reload": tab.reload()
            default: tab.stop()
            }
            if command != "page.stop", args["wait"] as? Bool ?? true {
                try await Task.sleep(nanoseconds: 60_000_000)
                try await waitForReadable(tab, timeout: args["timeout"] as? Double ?? 20)
                await settle(tab, tab.materialize())
            }
            return describe(tab, in: browser)

        case "page.wait":
            let (view, tab, browser) = try await webView(args)
            let timeout = args["timeout"] as? Double ?? 20
            if let gone = args["gone"] as? String {
                // Until it's gone: a "Verifying…", a spinner's words, the old results.
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if (try? await evaluate("return window.__sillAgent.absent(text)", in: view, world: Web.world, arguments: ["text": gone])) as? Bool == true { return describe(tab, in: browser) }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                throw AgentError("“\(gone)” was still there after \(Int(timeout)) s.")
            } else if args["input"] as? Bool == true {
                // Until the page asks for input again: a field that wasn't usable when the wait began is now.
                let deadline = Date().addingTimeInterval(timeout)
                let start = (try? await evaluate("return window.__sillAgent.inputs()", in: view, world: Web.world)) as? [String: Any] ?? [:]
                let before = Set(start["on"] as? [String] ?? []), buttonsBefore = Set(start["buttons"] as? [String] ?? [])
                var firstLoop = true
                while Date() < deadline {
                    let now = (try? await evaluate("return window.__sillAgent.inputs()", in: view, world: Web.world)) as? [String: Any] ?? [:]
                    let on = now["on"] as? [String] ?? []
                    let fresh = on.filter { !before.contains($0) }
                    // A field newly switched on, or (on a page that had none usable) any usable one.
                    if !fresh.isEmpty || (before.isEmpty && !on.isEmpty && !firstLoop) {
                        let names = now["names"] as? [String] ?? []
                        return ["field": names.first ?? "", "url": view.url?.absoluteString ?? ""]
                    }
                    // No field coming, but a new button: the page is waiting on a click (a "Next", a "DESCEND"),
                    // once it has held still a moment. Said at once rather than after the whole wait.
                    let newButtons = (now["buttons"] as? [String] ?? []).filter { !buttonsBefore.contains($0) }
                    let state = (try? await evaluate("return window.__sillAgent.state()", in: view, world: Web.world)) as? [String: Any]
                    let still = state?["still"] as? Double ?? 0
                    if !newButtons.isEmpty, still >= 700 {
                        return ["waitsOn": newButtons.prefix(3).joined(separator: "”, “"), "url": view.url?.absoluteString ?? ""]
                    }
                    // Still for a second and nothing to type in: hand back the buttons there are, for the caller to
                    // tell which ones are new since the agent last looked (it keeps what it was shown).
                    if args["early"] as? Bool != false, still >= 1000, Date().timeIntervalSince(deadline.addingTimeInterval(-timeout)) >= 1.5 {
                        return ["still": true, "buttons": now["buttons"] as? [String] ?? [], "url": view.url?.absoluteString ?? ""]
                    }
                    firstLoop = false
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                throw AgentError("The page didn't ask for input within \(Int(timeout)) s.")
            } else if args["settled"] as? Bool == true {
                // Until the page has held still for half a second: results that arrive in parts.
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    let state = (try? await evaluate("return window.__sillAgent.state()", in: view, world: Web.world)) as? [String: Any]
                    // Held still: nothing changing, or only text ticking in place (a timer) while its shape holds.
                    let idle = state?["idle"] as? Double ?? 0, still = state?["still"] as? Double ?? 0
                    if idle >= 500 || still >= 700, !AgentPage.of(view).fetching(since: .distantPast) { return describe(tab, in: browser) }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                return describe(tab, in: browser)
            } else if let selector = args["selector"] as? String {
                try await waitFor(selector: selector, text: nil, in: view, timeout: timeout)
            } else if let text = args["text"] as? String {
                let count = { (try? await evaluate("return window.__sillAgent.textCount(text)", in: view, world: Web.world, arguments: ["text": text])) as? Int ?? 0 }
                // "measure": how often the words show now, taken before an action whose answer is awaited.
                // The document's identity (its time origin): a reload or a new page is new even at the same address.
                let document = { (try? await evaluate("return String(performance.timeOrigin)", in: view, world: Web.world)) as? String ?? "" }
                if args["measure"] as? Bool == true { return ["count": await count(), "url": await document()] }
                // Words that were already there before the action don't answer the wait: it waits for
                // them to show again (a new result, the next page) and says so if they never do.
                if let before = args["before"] as? Int, before > 0 {
                    let deadline = Date().addingTimeInterval(min(timeout, 3)), url = args["beforeURL"] as? String
                    var fresh = false
                    while true {
                        let now = await count()
                        if now > before { fresh = true; break }
                        if now > 0, let url, await document() != url { fresh = true; break }
                        if Date() >= deadline { break }
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                    var answer = describe(tab, in: browser)
                    if !fresh { answer["already"] = true }
                    return answer
                }
                try await waitFor(selector: nil, text: text, in: view, timeout: timeout)
            } else {
                try await waitForLoad(tab, timeout: timeout)
            }
            return describe(tab, in: browser)

        case "page.text":
            let (view, _, _) = try await webView(args)
            let limit = args["maxChars"] as? Int ?? 40_000
            // A PDF in the tab: read as a document, page by page.
            if PDFTabs.isPDF(view.url), let url = view.url {
                var r = try await PDFTabs.text(url, pages: args["pages"] as? String, maxChars: limit)
                r["url"] = url.absoluteString; r["title"] = view.title ?? url.lastPathComponent
                return r
            }
            // Markdown (headings, lists, table rows) through shadow roots and frames; plain innerText if that fails.
            let main = args["main"] as? Bool ?? false
            if args["raw"] as? Bool != true,
               let md = try? await evaluate("return window.__sillAgent.markdown(main, max)", in: view, world: Web.world,
                                            arguments: ["main": main, "max": limit]) as? [String: Any],
               let text = md["text"] as? String, !text.isEmpty {
                return ["url": view.url?.absoluteString ?? "", "title": view.title ?? "", "text": text,
                        "truncated": md["truncated"] as? Bool ?? false, "main": md["main"] as? Bool ?? false]
            }
            let text = try await evaluate("return (document.body ? document.body.innerText : '')", in: view, world: Web.world) as? String ?? ""
            return ["url": view.url?.absoluteString ?? "", "title": view.title ?? "",
                    "text": String(text.prefix(limit)), "truncated": text.count > limit]

        case "page.snapshot":
            let (view, tab, _) = try await webView(args)
            var answer: [String: Any] = ["tab": tab.id.uuidString, "url": view.url?.absoluteString ?? "", "title": view.title ?? ""]
            if let dialog = view.openDialog {
                answer["dialog"] = dialog
                answer["elements"] = [Any]()
                return answer
            }
            let all = args["all"] as? Bool ?? false
            // What's in the way first (a cookie banner, a newsletter pop-up), so the page is read as it is under them.
            var cleared: [String] = []
            if args["clear"] as? Bool != false, view.openDialog == nil {
                var closed = (try? await evaluate("return window.__sillAgent.clearWay()", in: view, world: Web.world) as? [String]) ?? []
                // A consent service's banner in a frame of its own (another site): the same, inside it.
                closed += await AgentPage.of(view).clearFrames()
                if !closed.isEmpty {
                    cleared = closed
                    if closed.contains(where: { !$0.hasPrefix("a cookie banner is up") }) { try? await Task.sleep(nanoseconds: 250_000_000) }
                }
            }
            // Mid-navigation (a redirect, a new document) the script answers
            // nothing: wait for the page and look again, never report an empty page.
            var listed = try? await evaluate("return window.__sillAgent.snapshot(all)", in: view, world: Web.world,
                                             arguments: ["all": all]) as? [[String: Any]]
            if listed == nil || (listed?.isEmpty == true && view.isLoading) {
                try? await waitForReadable(tab, timeout: 8)
                listed = try? await evaluate("return window.__sillAgent.snapshot(all)", in: view, world: Web.world,
                                             arguments: ["all": all]) as? [[String: Any]]
            }
            // Nothing at all on a page that says it's loaded: an interstitial (a bot check that clears itself,
            // a redirect by script) or a page still drawing itself. Give it up to 4 s to move on or fill in.
            let substance: ([[String: Any]]?) -> Bool = { list in
                (list ?? []).contains { e in (e["context"] as? String).map { !["page", "state", "list", "map"].contains($0) } ?? true }
            }
            if listed != nil, !substance(listed) {
                let start = Date(), from = view.url
                while Date().timeIntervalSince(start) < 4 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if view.isLoading || view.url != from { try? await waitForReadable(tab, timeout: 6) }
                    let again = try? await evaluate("return window.__sillAgent.snapshot(all)", in: view, world: Web.world,
                                                    arguments: ["all": all]) as? [[String: Any]]
                    if substance(again) { listed = again; break }
                }
            }
            var elements = listed ?? []
            // Still arriving with nothing to act on yet: say so. A parsed page still fetching images is ready.
            if listed == nil || (elements.isEmpty && view.isLoading) { answer["loading"] = true }
            answer["url"] = view.url?.absoluteString ?? ""
            answer["title"] = view.title ?? ""
            let page = AgentPage.of(view)
            if let tokens = try? await evaluate("return window.__sillAgent.opaque()", in: view, world: Web.world) as? [String], !tokens.isEmpty {
                elements += await page.hiddenElements(tokens: tokens)
            }
            elements += await page.frameElements(all: all)
            answer["elements"] = elements
            answer["walls"] = (try? await evaluate("return window.__sillAgent.walls()", in: view, world: Web.world)) as? [String] ?? []
            if !cleared.isEmpty { answer["cleared"] = cleared }
            return answer

        case "page.click":
            let (view, tab, _) = try await webView(args)
            // A point (CSS pixels, from a screenshot or a box) when there's no element to name: canvases, maps.
            let target: Target
            if let x = args["x"] as? Double, let y = args["y"] as? Double, args["ref"] == nil, args["selector"] == nil, args["text"] == nil {
                target = Target(ref: "\(Int(x)),\(Int(y))", x: x, y: y, name: "the point \(Int(x)), \(Int(y))")
            } else {
                target = try await locate(args, in: view)
                try target.mustBeClickable()
            }
            let double = args["double"] as? Bool ?? false
            let started = Date()
            // Armed first: afterwards Sill can say whether the click reached it.
            let answerURL = view.url?.absoluteString
            let armRef = target.inner ?? target.ref
            let armed: Bool
            if let frame = target.frame {
                armed = (try? await AgentPage.of(view).evaluate("window.__sillAgent.arm(\(json(armRef)), \(json(args["button"] as? String ?? "left")))", in: frame)) as? Bool == true
            } else if target.backend == nil, target.ref.hasPrefix("e") {
                armed = (try? await evaluate("return window.__sillAgent.arm(ref, button)", in: view, world: Web.world,
                                             arguments: ["ref": armRef, "button": args["button"] as? String ?? "left"])) as? Bool == true
            } else { armed = false }
            // Something that opens, closed now: if the click leaves it closed, the page wasn't ready (a page
            // drawn on the server whose script hadn't taken over yet): once more after a moment, as a person would.
            var opens = false
            if !double, (args["button"] as? String ?? "left") == "left", target.frame == nil, target.backend == nil, target.ref.hasPrefix("e") {
                opens = (try? await evaluate("return window.__sillAgent.expanded(ref)", in: view, world: Web.world, arguments: ["ref": target.ref])) as? String == "false"
            }
            do {
                try await click(at: target.x, target.y, in: view, count: double ? 2 : 1,
                                button: args["button"] as? String ?? "left", hold: args["hold"] as? Double ?? 0,
                                modifiers: modifierMask(args["modifiers"]))
            } catch where target.frame == nil && target.backend == nil && target.ref.hasPrefix("e") && view.openDialog == nil {
                _ = try await evaluate("return window.__sillAgent.click(ref)", in: view, world: Web.world, arguments: ["ref": target.ref])
            }
            var landed: [String: Any]?
            if armed, view.openDialog == nil {
                if let frame = target.frame {
                    landed = (try? await AgentPage.of(view).evaluate("window.__sillAgent.landed()", in: frame)) as? [String: Any]
                } else {
                    landed = (try? await evaluate("return window.__sillAgent.landed()", in: view, world: Web.world)) as? [String: Any]
                }
            }
            await settle(tab, view, since: started)
            if opens, view.openDialog == nil {
                let js = "return window.__sillAgent.expanded(ref)"
                if (try? await evaluate(js, in: view, world: Web.world, arguments: ["ref": target.ref])) as? String == "false" {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if (try? await evaluate(js, in: view, world: Web.world, arguments: ["ref": target.ref])) as? String == "false", let r = try? await evaluate("return window.__sillAgent.rect(ref)", in: view, world: Web.world, arguments: ["ref": target.ref]) as? [String: Any],
                       let x = r["x"] as? Double, let y = r["y"] as? Double, let w = r["w"] as? Double, let h = r["h"] as? Double {
                        try? await click(at: x + w / 2, y + h / 2, in: view, count: 1, button: "left", hold: 0, modifiers: modifierMask(nil))
                        await settle(tab, view, since: Date())
                    }
                }
            }
            // A link may open a tab: Chromium makes it a moment after the click.
            if target.name.hasPrefix("link"), adoptedFrom[ObjectIdentifier(tab)].map({ $0.at < started }) ?? true {
                for _ in 0..<15 where adoptedFrom[ObjectIdentifier(tab)].map({ $0.at < started }) ?? true { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
            var answer: [String: Any] = ["clicked": target.ref, "name": target.name]
            if let from = answerURL { answer["from"] = from }   // where it was: a click that went somewhere can be undone
            if target.partial { answer["partial"] = true }
            // No click arrived at all (and the page didn't move on): say so, never "clicked".
            let urlBefore = answerURL
            if armed, landed == nil, view.openDialog == nil, !view.isLoading, view.url?.absoluteString == urlBefore {
                answer["missed"] = "No click reached “\(target.name)”: something on the page took it. Look again (page_screenshot marks=true shows what's where)."
            }
            // The page moved between finding it and clicking: say what was really clicked.
            if let landed, landed["hit"] as? Bool == false {
                answer["missed"] = "The click landed on “\(landed["on"] as? String ?? "something else")”, not on “\(target.name)”: the page moved. Look again before going on."
            }
            if answer["missed"] == nil, target.backend == nil, !target.ref.contains(",") { SiteNotes.shared.did(tab, url: URL(string: answerURL ?? ""), click: target.name) }
            return outcome(answer, view, since: started)

        case "page.hover":
            let (view, _, _) = try await webView(args)
            let target = try await locate(args, in: view)
            try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": target.x, "y": target.y])
            try await Task.sleep(nanoseconds: 150_000_000)
            return ["hovered": target.ref]

        case "page.type":
            let (view, tab, _) = try await webView(args)
            guard let text = args["text"] as? String else { throw AgentError("Missing \"text\".") }
            // Here "text" is what to type; the field is found by ref, selector or its label.
            var lookup: [String: Any] = ["editable": true]
            for (key, from) in [("ref", "ref"), ("selector", "selector"), ("text", "label"), ("wait", "wait")] { if let v = args[from] { lookup[key] = v } }
            let target = try await locate(lookup, in: view)
            if target.disabled { throw AgentError("“\(target.name)” is disabled.") }
            let clear = args["clear"] as? Bool ?? true
            let typingStarted = Date()
            let typed = try await type(text, into: target, clear: clear, in: view)
            if typed.ok, !(typed.value ?? "").isEmpty, (try? await evaluate("return window.__sillAgent.valueKind(ref)", in: view, world: Web.world, arguments: ["ref": typed.into ?? target.ref])) as? String != "password" {
                SiteNotes.shared.did(tab, url: view.url, typeInto: target.name)
                SiteNotes.shared.agentTyped(text, in: tab)
            }
            // Suggestions, validation: what the typing set off, before answering.
            await settle(tab, view, since: typingStarted)
            if args["submit"] as? Bool ?? false {
                try await key("Enter", in: view)
                await settle(tab, view)
            }
            var answer: [String: Any] = ["typed": typed.ok, "ref": typed.into ?? target.ref]
            if let into = typed.into { answer["followed"] = into }
            if let value = typed.value { answer["value"] = value }
            return outcome(answer, view, since: Date())

        case "page.select":
            let (view, _, _) = try await webView(args)
            guard let value = args["value"] as? String else { throw AgentError("Missing \"value\".") }
            let target = try await locate(args, in: view)
            if target.disabled { throw AgentError("“\(target.name)” is disabled.") }
            let chosen: Any?
            if let frame = target.frame {
                chosen = try await AgentPage.of(view).evaluate("window.__sillAgent.choose(\(json(target.inner)), \(json(value)))", in: frame)
            } else {
                chosen = try await evaluate("return window.__sillAgent.choose(ref, value)", in: view, world: Web.world,
                                            arguments: ["ref": target.ref, "value": value])
            }
            if chosen as? Bool != true, target.frame == nil,
               (try? await evaluate("return window.__sillAgent.isSelect(ref)", in: view, world: Web.world, arguments: ["ref": target.ref])) as? Bool == false {
                // A dropdown the page draws itself (a button and a list): open it, then choose the option by name, as a person does.
                var tabArgs: [String: Any] = [:]
                for k in ["tab", "_session", "remember"] { if let v = args[k] { tabArgs[k] = v } }
                var option = (try? await evaluate("return window.__sillAgent.optionRef(ref, value)", in: view, world: Web.world, arguments: ["ref": target.ref, "value": value])) as? String
                if option == nil {
                    _ = try await perform("page.click", tabArgs.merging(["ref": target.ref]) { $1 })
                    option = (try? await evaluate("return window.__sillAgent.optionRef(ref, value)", in: view, world: Web.world, arguments: ["ref": target.ref, "value": value])) as? String
                }
                guard let option else { throw AgentError("Opened “\(target.name)”, but no option “\(value)” showed in its list.") }
                let clicked = try await perform("page.click", tabArgs.merging(["ref": option]) { $1 })
                var answer = clicked as? [String: Any] ?? [:]
                answer["selected"] = true
                return answer
            }
            if chosen as? Bool != true {
                let options = (try? await evaluate("return window.__sillAgent.options(ref)", in: view, world: Web.world,
                                                   arguments: ["ref": target.ref])) as? [String] ?? []
                throw AgentError("No option “\(value)” in “\(target.name)”.\(options.isEmpty ? "" : " Options: " + options.prefix(30).joined(separator: ", "))")
            }
            return ["selected": true]

        case "page.press":
            let (view, tab, _) = try await webView(args)
            guard let name = args["key"] as? String else { throw AgentError("Missing \"key\".") }
            // Aimed at an element (a slider, a grid cell): it gets the focus first.
            if args["ref"] != nil || args["selector"] != nil || args["text"] != nil {
                let target = try await locate(args, in: view)
                try await focus(target, in: view)
            }
            let started = Date()
            try await key(name, in: view)
            await settle(tab, view)
            return outcome(["pressed": name], view, since: started)

        case "page.scroll":
            let (view, _, _) = try await webView(args)
            let named = args["ref"] != nil || args["selector"] != nil || args["text"] != nil
            var at: (x: Double, y: Double)?
            if named {
                let target = try await locate(args, in: view)
                // Just a target: bring it into view. With dy/dx: turn the wheel over it (a list, a map, a panel).
                if args["dy"] == nil && args["dx"] == nil { return ["scrolledTo": target.ref] }
                at = (target.x, target.y)
            }
            let dy = args["dy"] as? Double ?? 600
            let dx = args["dx"] as? Double ?? 0
            // A real wheel turn in the middle of the page: what's under it
            // scrolls, inner panels too, as with a trackpad.
            let size = try await evaluate("return [innerWidth, innerHeight]", in: view, world: Web.world) as? [Double] ?? [800, 600]
            let x = at?.x ?? args["x"] as? Double ?? size[0] / 2, y = at?.y ?? args["y"] as? Double ?? size[1] / 2
            do {
                try await devtools(view, "Input.dispatchMouseEvent",
                                   ["type": "mouseWheel", "x": x, "y": y, "deltaX": dx, "deltaY": dy])
            } catch {
                _ = try await evaluate("window.scrollBy({left: dx, top: dy, behavior: 'instant'})", in: view, world: Web.world,
                                       arguments: ["dx": dx, "dy": dy])
            }
            try await Task.sleep(nanoseconds: 120_000_000)
            let position = try await evaluate("return [scrollY, document.documentElement.scrollHeight - innerHeight]", in: view,
                                              world: Web.world) as? [Double] ?? []
            return ["scrolled": dy, "scrollY": position.first ?? 0, "maxScrollY": position.last ?? 0]

        case "page.eval":
            let (view, _, _) = try await webView(args)
            guard let script = args["script"] as? String else { throw AgentError("Missing \"script\" (a function body; use return).") }
            // A script can do anything the page can, unjudged: from claude.ai only if you've allowed it.
            if args["_via"] as? String == "relay", !Preferences.shared.remoteScripts {
                throw AgentError("Running scripts is off for claude.ai (Sill › Settings › Agents). Use the other tools: page_snapshot, page_text, page_click, page_type.")
            }
            let value = try await evaluate(script, in: view, world: .page, timeout: 30)
            return ["value": sanitize(value)]

        case "page.records":
            let (view, _, _) = try await webView(args)
            let rows = try await evaluate("return window.__sillAgent.records(max)", in: view, world: Web.world, arguments: ["max": args["max"] as? Int ?? 200])
            return ["url": view.url?.absoluteString ?? "", "records": sanitize(rows)]

        case "page.screenshot":
            let (view, _, _) = try await webView(args)
            // A page of a PDF in the tab, drawn whole at full size.
            if let n = args["pdfPage"] as? Int, let url = view.url, PDFTabs.isPDF(url) {
                return try await PDFTabs.picture(url, page: n, width: min(max(args["maxWidth"] as? Double ?? 1600, 600), 2400))
            }
            // Just a part, larger: an element (ref) or a region, at zoom times its size.
            if args["ref"] != nil || args["w"] != nil {
                var region: [String: Double] = [:]
                if let ref = args["ref"] as? String {
                    guard let r = try await evaluate("return window.__sillAgent.rect(ref)", in: view, world: Web.world, arguments: ["ref": ref]) as? [String: Any] else {
                        throw AgentError("\(ref) isn't on the page now: look again for its ref.")
                    }
                    for k in ["x", "y", "w", "h"] { region[k] = (r[k] as? Double) ?? Double(r[k] as? Int ?? 0) }
                } else {
                    for k in ["x", "y", "w", "h"] { region[k] = args[k] as? Double ?? Double(args[k] as? Int ?? 0) }
                }
                guard (region["w"] ?? 0) >= 4, (region["h"] ?? 0) >= 4 else { throw AgentError("That region is too small to picture.") }
                let scroll = try await evaluate("return [scrollX, scrollY]", in: view, world: Web.world) as? [Double] ?? [0, 0]
                let zoom = min(max(args["zoom"] as? Double ?? 2, 1), 4)
                if view.pageHidden { view.insistShown() }
                let shot = try await devtools(view, "Page.captureScreenshot", ["format": "jpeg", "quality": 90,
                    "clip": ["x": (region["x"] ?? 0) + scroll[0], "y": (region["y"] ?? 0) + scroll[1], "width": region["w"] ?? 0, "height": region["h"] ?? 0, "scale": zoom]], timeout: 8)
                guard let data = shot["data"] as? String else { throw AgentError("The page couldn't be captured.") }
                return ["data": data, "mimeType": "image/jpeg",
                        "note": "That part at \(String(format: "%.1f", zoom))× (the box \(Int(region["x"] ?? 0)),\(Int(region["y"] ?? 0)) \(Int(region["w"] ?? 0))×\(Int(region["h"] ?? 0)) in CSS pixels)."]
            }
            var marks: [[String: Any]] = []
            if args["marks"] as? Bool == true {
                marks = (try? await evaluate("return window.__sillAgent.snapshot(false)", in: view, world: Web.world)) as? [[String: Any]] ?? []
                marks += await AgentPage.of(view).frameElements(all: false)
                marks = marks.filter { $0["ref"] != nil }
            }
            let cssWidth = (try? await evaluate("return innerWidth", in: view, world: Web.world)) as? Double ?? Double(view.bounds.width)
            return try await screenshot(of: view, maxWidth: args["maxWidth"] as? Double ?? 1280,
                                        quality: args["quality"] as? Double ?? 0.75, marks: marks, cssWidth: cssWidth)

        case "page.find":
            let (view, _, _) = try await webView(args)
            guard let text = args["text"] as? String else { throw AgentError("Missing \"text\".") }
            let configuration = WKFindConfiguration()
            configuration.caseSensitive = false
            let found = try await view.find(text, configuration: configuration)
            return ["found": found.matchFound]

        case "habits.site":
            // Where you go on a site and what you click there (Habits.swift).
            guard Habits.shared.enabled else {
                let host = (args["host"] as? String) ?? ""
                return ["pages": [], "clicks": [], "off": true, "notes": SiteNotes.shared.brief(for: host)]
            }
            let host = (args["host"] as? String) ?? (try? tab(args.merging(["remember": false]) { $1 }).0.webView?.url?.host()) ?? ""
            guard !host.isEmpty else { throw AgentError("Give a \"host\".") }
            let page = (args["url"] as? String).flatMap(URL.init(string:))
            var site = Habits.shared.site(host, page: page, limit: args["limit"] as? Int ?? 6)
            site["notes"] = SiteNotes.shared.brief(for: host)
            return site

        case "habits.search":
            guard Habits.shared.enabled else {
                let visits = History.shared.search(args["query"] as? String ?? "", limit: args["limit"] as? Int ?? 12)
                return ["pages": visits.map { ["url": $0.url, "title": $0.title, "visits": $0.count,
                                               "last": ISO8601DateFormatter().string(from: $0.last)] }, "clicks": []]
            }
            return Habits.shared.search(args["query"] as? String ?? "", limit: args["limit"] as? Int ?? 12)

        case "habits.record":
            // The test course only: a click as if the user made it.
            guard Places.testProfile != nil, let page = (args["page"] as? String).flatMap(URL.init(string:)) else {
                throw AgentError("Only in a test copy of Sill.")
            }
            Habits.shared.record(page: page, role: args["role"] as? String ?? "link", name: args["name"] as? String ?? "",
                                 to: (args["to"] as? String).flatMap(URL.init(string:)), title: args["title"] as? String)
            return ["recorded": true]

        case "files.find":
            guard Preferences.shared.agentFiles else { throw AgentError("Finding files is off in Sill's settings (Agents › Let agents find and read my files).") }
            return try await Files.find(args["query"] as? String ?? "", limit: min(args["limit"] as? Int ?? 20, 60))

        case "files.read":
            guard Preferences.shared.agentFiles else { throw AgentError("Reading files is off in Sill's settings (Agents › Let agents find and read my files).") }
            guard let path = args["path"] as? String, !path.isEmpty else { throw AgentError("Give a \"path\".") }
            let full = (path as NSString).expandingTildeInPath
            guard everyday(full) else {
                throw AgentError("Only files in Desktop, Documents, Downloads, Pictures, Movies, Music or iCloud Drive (not hidden ones) can be read.")
            }
            return try await Files.read(full, maxChars: args["maxChars"] as? Int ?? 30_000)

        case "tabs.split":
            // Two tabs side by side in your window: yours (or one named) on the left, the agent's on the right.
            let (tab, browser) = try tab(args)
            if args["off"] as? Bool == true {
                if browser.split?.contains(tab) == true { browser.unsplit() }
                return describe(tab, in: browser)
            }
            let partner: Tab
            if let id = args["with"] as? String {
                guard let other = browser.tabs.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                    throw AgentError("The other tab has to be in the same window. Open it there, or leave out \"with\" to pair with the tab in front.")
                }
                partner = other
            } else {
                guard let front = browser.selected, front !== tab else {
                    throw AgentError("Your tab is the one in front: name another with \"with\".")
                }
                partner = front
            }
            guard !browser.isPrivate else { throw AgentError("Not in a private window.") }
            tab.keptForUser = true
            if browser.split != nil { browser.unsplit() }
            browser.select(partner)
            browser.split(tab, onLeft: args["left"] as? Bool ?? false)
            browser.window?.orderFront(nil)
            return ["left": describe(browser.split?.left ?? partner, in: browser), "right": describe(browser.split?.right ?? tab, in: browser)]

        case "history.search":
            let query = args["query"] as? String ?? ""
            let limit = args["limit"] as? Int ?? 20
            let visits = query.isEmpty ? History.shared.recent(limit: limit) : History.shared.search(query, limit: limit)
            return visits.map { ["url": $0.url, "title": $0.title, "visits": $0.count,
                                 "last": ISO8601DateFormatter().string(from: $0.last)] }

        case "page.drag":
            // Press, move along a path, let go: sliders, canvases, maps, sortable lists.
            let (view, tab, _) = try await webView(args)
            let source = try await target(args, prefix: "from", in: view)
            let from = (x: source.x, y: source.y)
            // A path relative to where it starts (drawing, a gesture), or a destination.
            let path: [(Double, Double)] = (args["by"] as? [[Double]] ?? []).compactMap { $0.count >= 2 ? (from.x + $0[0], from.y + $0[1]) : nil }
            if !path.isEmpty {
                try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": from.x, "y": from.y])
                try await devtools(view, "Input.dispatchMouseEvent", ["type": "mousePressed", "x": from.x, "y": from.y,
                                                                      "button": "left", "buttons": 1, "clickCount": 1])
                var last = from
                for point in path {
                    for i in 1...8 {
                        let t = Double(i) / 8
                        try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "button": "left", "buttons": 1,
                                                                              "x": last.x + (point.0 - last.x) * t, "y": last.y + (point.1 - last.y) * t])
                        try await Task.sleep(nanoseconds: 8_000_000)
                    }
                    last = (point.0, point.1)
                }
                try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseReleased", "x": last.x, "y": last.y,
                                                                      "button": "left", "buttons": 0, "clickCount": 1])
                await settle(tab, view)
                return ["dragged": ["from": [from.x, from.y], "points": path.count]]
            }
            let to = try await point(args, prefix: "to", in: view)
            let steps = max(2, min(60, args["steps"] as? Int ?? 16))
            // HTML drag and drop (draggable="true"): Chromium hands the drag
            // over, and it's carried to the drop point as a drag, not a mouse move.
            var html5 = false
            if source.frame == nil, source.backend == nil, source.ref.hasPrefix("e") {
                html5 = (try? await evaluate("return window.__sillAgent.draggable(ref)", in: view, world: Web.world,
                                             arguments: ["ref": source.ref])) as? Bool == true
            }
            if html5 {
                let page = AgentPage.of(view)
                try await devtools(view, "Input.setInterceptDrags", ["enabled": true])
                defer { Task { _ = try? await devtools(view, "Input.setInterceptDrags", ["enabled": false]) } }
                try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": from.x, "y": from.y])
                try await devtools(view, "Input.dispatchMouseEvent", ["type": "mousePressed", "x": from.x, "y": from.y,
                                                                      "button": "left", "buttons": 1, "clickCount": 1])
                async let data = page.nextDrag(timeout: 2)
                for i in 1...6 {
                    try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "button": "left", "buttons": 1,
                                                                          "x": from.x + (to.x - from.x) * Double(i) / 30, "y": from.y + (to.y - from.y) * Double(i) / 30])
                }
                if let carried = await data {
                    for kind in ["dragEnter", "dragOver", "drop"] {
                        try await devtools(view, "Input.dispatchDragEvent", ["type": kind, "x": to.x, "y": to.y, "data": carried])
                    }
                    try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseReleased", "x": to.x, "y": to.y,
                                                                          "button": "left", "buttons": 0, "clickCount": 1])
                    await settle(tab, view)
                    return ["dragged": ["from": [from.x, from.y], "to": [to.x, to.y]], "kind": "drag and drop"]
                }
                try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseReleased", "x": from.x, "y": from.y,
                                                                      "button": "left", "buttons": 0, "clickCount": 1])
            }
            try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": from.x, "y": from.y])
            try await devtools(view, "Input.dispatchMouseEvent", ["type": "mousePressed", "x": from.x, "y": from.y,
                                                                  "button": "left", "buttons": 1, "clickCount": 1])
            for i in 1...steps {
                let t = Double(i) / Double(steps), eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "button": "left", "buttons": 1,
                                                                      "x": from.x + (to.x - from.x) * eased, "y": from.y + (to.y - from.y) * eased])
                try await Task.sleep(nanoseconds: 12_000_000)
            }
            try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseReleased", "x": to.x, "y": to.y,
                                                                  "button": "left", "buttons": 0, "clickCount": 1])
            await settle(tab, view)
            return ["dragged": ["from": [from.x, from.y], "to": [to.x, to.y]]]

        case "page.touch":
            // A finger: tap, long press, or swipe by dx/dy, as a phone-sized page expects.
            let (view, tab, _) = try await webView(args)
            let at = try await point(args, prefix: "", in: view)
            let kind = (args["kind"] as? String ?? "tap").lowercased()
            let dx = args["dx"] as? Double ?? 0, dy = args["dy"] as? Double ?? 0
            let duration = args["duration"] as? Double ?? (kind == "longpress" ? 0.8 : kind == "swipe" ? 0.3 : 0.05)
            try await devtools(view, "Input.dispatchTouchEvent", ["type": "touchStart", "touchPoints": [["x": at.x, "y": at.y]]])
            if kind == "swipe" {
                let steps = 12
                for i in 1...steps {
                    let t = Double(i) / Double(steps), eased = 1 - pow(1 - t, 3)
                    try await devtools(view, "Input.dispatchTouchEvent", ["type": "touchMove",
                                                                          "touchPoints": [["x": at.x + dx * eased, "y": at.y + dy * eased]]])
                    try await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1e9))
                }
            } else {
                try await Task.sleep(nanoseconds: UInt64(duration * 1e9))
            }
            try await devtools(view, "Input.dispatchTouchEvent", ["type": "touchEnd", "touchPoints": [[String: Any]]()])
            await settle(tab, view)
            return ["touched": kind]

        case "page.pinch":
            let (view, _, _) = try await webView(args)
            let at = try await point(args, prefix: "", in: view)
            let scale = args["scale"] as? Double ?? 2
            try await devtools(view, "Input.synthesizePinchGesture", ["x": at.x, "y": at.y, "scaleFactor": scale,
                                                                      "gestureSourceType": "touch"], timeout: 15)
            return ["pinched": scale]

        case "page.zoom":
            let (view, _, _) = try await webView(args)
            if let level = args["level"] as? Double { view.pageZoom = max(0.25, min(5, level)) }
            return ["zoom": view.pageZoom]

        case "page.upload":
            // Files from this Mac into a page.
            let (view, _, _) = try await webView(args)
            let paths = (args["paths"] as? [String] ?? []).map { ($0 as NSString).expandingTildeInPath }
            guard !paths.isEmpty else { throw AgentError("Give \"paths\": the files to upload.") }
            for path in paths where !FileManager.default.isReadableFile(atPath: path) { throw AgentError("Can't read \(path).") }
            let target = try await locate(args, in: view)
            guard target.backend == nil else { throw AgentError("That field is inside a closed component; uploads can't reach it.") }
            let site = target.frame.flatMap { URL(string: $0.url)?.host } ?? view.url?.host ?? "this page"
            // Claude asks in the chat before uploading. Sill asks too only for files
            // outside your everyday folders (keys, settings, hidden files): what a
            // page's hidden instructions would be after.
            // (The agent test course's own copy of Sill never asks.)
            if Places.testProfile == nil, paths.contains(where: { !everyday($0) }), !(await ConnectorApproval.allowUpload(paths, to: site)) {
                throw AgentError("The user didn't allow uploading those files. Ask them in chat.")
            }
            return try await upload(paths, into: target, in: view)


        case "user.wait":
            // A wall only a person should get past (a CAPTCHA, a code sent to
            // their phone): Sill asks for them, and waits until it's gone.
            let (view, tab, browser) = try await webView(args)
            let message = (args["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "The agent needs you in “\(tab.displayTitle)”."
            let timeout = min(600, args["timeout"] as? Double ?? 180)
            NSApp.requestUserAttention(.criticalRequest)
            browser.toast("Sill needs you: \(message)")
            let start = Date()
            while Date().timeIntervalSince(start) < timeout {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                AgentActivity.shared.touch(tab, view: view, in: browser)
                let walls = (try? await evaluate("return window.__sillAgent.walls()", in: view, world: Web.world)) as? [String] ?? []
                if walls.isEmpty, args["until"] == nil { break }
                if let text = args["until"] as? String,
                   (try? await evaluate("return window.__sillAgent.present(null, text)", in: view, world: Web.world,
                                        arguments: ["text": text])) as? Bool == true { break }
            }
            let waited = Int(Date().timeIntervalSince(start))
            let walls = (try? await evaluate("return window.__sillAgent.walls()", in: view, world: Web.world)) as? [String] ?? []
            return ["cleared": walls.isEmpty, "waitedSeconds": waited, "url": view.url?.absoluteString ?? ""]

        case "page.dialog":
            // The page's alert, confirm or prompt, held while the agent works: answered here.
            let (view, tab, _) = try await webView(args)
            guard let dialog = view.openDialog else { return ["answered": false, "note": "No dialog is open."] }
            let accept = args["accept"] as? Bool ?? true
            _ = view.answerDialog(accept, text: args["text"] as? String)
            await settle(tab, view)
            return ["answered": true, "kind": dialog["kind"] ?? "", "message": dialog["message"] ?? "", "accepted": accept]

        case "passwords.list":
            // Names only: which accounts Sill could sign in with here.
            let (view, _, _) = try await webView(args)
            let host = (args["host"] as? String) ?? view.url?.host ?? ""
            guard !host.isEmpty else { throw AgentError("No site to look up.") }
            return ["host": host, "accounts": await SavedPasswords.logins(for: host).map { ["host": $0.host, "user": $0.user] }]

        case "page.signin":
            // Sill fills the saved password itself: the agent never sees it,
            // and it's only ever filled on the site it was saved for.
            let (view, tab, _) = try await webView(args)
            guard let url = view.url, let host = url.host else { throw AgentError("The page has no address yet.") }
            guard url.scheme == "https" || ["localhost", "127.0.0.1"].contains(host) else {
                throw AgentError("Saved passwords are only filled on https pages.")
            }
            let logins = await SavedPasswords.logins(for: host)
            let wanted = (args["user"] as? String)?.lowercased()
            guard let login = wanted.map({ w in logins.first { $0.user.lowercased() == w } }) ?? logins.first else {
                throw AgentError(logins.isEmpty
                    ? "Sill has no saved password for \(host). Ask the user to sign in once (Sill offers to keep it), or create one with passwords_save on a sign-up form."
                    : "No saved account \(wanted ?? "") for \(host). Saved: \(logins.map(\.user).joined(separator: ", ")).")
            }
            guard let password = await SavedPasswords.password(for: login) else {
                throw AgentError("Sill couldn't read the saved password for \(login.user) from the Keychain.")
            }
            let filled = try await evaluate("return window.__sillFill ? window.__sillFill(user, password) : false", in: view,
                                            world: Web.world, arguments: ["user": login.user, "password": password]) as? Bool ?? false
            guard filled else { throw AgentError("No sign-in fields on this page. Open the sign-in form first.") }
            var submitted = false
            if args["submit"] as? Bool ?? true {
                try await key("Enter", in: view)
                submitted = true
                await settle(tab, view)
            }
            return ["signedInAs": login.user, "site": login.host, "submitted": submitted, "url": view.url?.absoluteString ?? ""]

        case "passwords.save":
            // A password for this site: given, or made up here (generate) and
            // filled into the page's new-password fields. Never sent back.
            let (view, _, _) = try await webView(args)
            let host = (args["host"] as? String) ?? view.url?.host ?? ""
            guard !host.isEmpty, let user = args["user"] as? String, !user.isEmpty else {
                throw AgentError("Give \"user\" (and the site's page open, or \"host\").")
            }
            let generate = args["generate"] as? Bool ?? (args["password"] == nil)
            guard let password = generate ? Self.strongPassword() : args["password"] as? String, !password.isEmpty else {
                throw AgentError("Give \"password\", or generate=true.")
            }
            let saved = await SavedPasswords.save(password, user: user, host: host)
            guard saved != .failed else { throw AgentError("The Keychain wouldn't keep it.") }
            var filledFields = 0
            if generate || args["fill"] as? Bool == true {
                filledFields = try await evaluate(Self.fillNewPassword, in: view, world: Web.world,
                                                  arguments: ["user": user, "password": password]) as? Int ?? 0
            }
            return ["saved": true, "user": user, "site": host, "generated": generate, "filledFields": filledFields]

        case "connector.approve":
            // Asked by the relay bridge when an app signs in from the internet.
            guard Preferences.shared.remoteConnector else { return ["approved": false] }
            let host = (args["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "An app"
            return ["approved": await ConnectorApproval.ask(host: host)]

        default:
            throw AgentError("Unknown command \"\(command)\". Commands: status, tabs.list, tabs.open, tabs.select, tabs.close, page.navigate, page.back, page.forward, page.reload, page.stop, page.wait, page.text, page.snapshot, page.click, page.hover, page.type, page.select, page.press, page.scroll, page.eval, page.screenshot, page.find, page.signin, page.dialog, page.drag, page.touch, page.pinch, page.zoom, page.upload, user.wait, passwords.list, passwords.save, history.search.")
        }
    }

    /// A point in CSS pixels: "<prefix>X"/"<prefix>Y" (or x/y), else the element
    /// named by "<prefix>Ref"/"<prefix>Selector"/"<prefix>Text" (or ref/selector/text).
    private static func point(_ args: [String: Any], prefix: String, in view: SillWebView) async throws -> (x: Double, y: Double) {
        let t = try await target(args, prefix: prefix, in: view)
        return (t.x, t.y)
    }

    private static func target(_ args: [String: Any], prefix: String, in view: SillWebView) async throws -> Target {
        func key(_ name: String) -> String { prefix.isEmpty ? name : prefix + name.prefix(1).uppercased() + name.dropFirst() }
        if let x = args[key("x")] as? Double, let y = args[key("y")] as? Double {
            return Target(ref: "\(Int(x)),\(Int(y))", x: x, y: y, name: "the point")
        }
        var picked: [String: Any] = [:]
        for name in ["ref", "selector", "text"] { if let value = args[key(name)] { picked[name] = value } }
        return try await locate(picked, in: view)
    }

    /// ["Meta", "Shift"] → DevTools' modifier bits (Alt 1, Ctrl 2, Meta 4, Shift 8).
    private static func modifierMask(_ value: Any?) -> Int {
        let names = (value as? [String]) ?? (value as? String).map { $0.split(separator: "+").map(String.init) } ?? []
        return names.reduce(0) { mask, name in
            switch name.lowercased() {
            case "alt", "option": return mask | 1
            case "ctrl", "control": return mask | 2
            case "meta", "cmd", "command": return mask | 4
            case "shift": return mask | 8
            default: return mask
            }
        }
    }

    /// Gives the file field (in the page, or in a frame from another site) the files.
    private static func upload(_ paths: [String], into target: Target, in view: SillWebView) async throws -> [String: Any] {
        // Marked in Sill's world, found in the page's, given the files: in the
        // page itself or inside its frame (a frame from another site has its own session).
        let token = UUID().uuidString
        let page = AgentPage.of(view)
        let find = "document.querySelector('[data-sill-pick=\"\(token)\"]')"
        let found: [String: Any]
        if let frame = target.frame {
            _ = try await page.evaluate("window.__sillAgent.mark(\(json(target.inner)), \(json(token)))", in: frame)
            found = try await page.call("Runtime.evaluate", ["expression": find], session: frame.session)
        } else {
            _ = try await evaluate("return window.__sillAgent.mark(ref, token)", in: view, world: Web.world,
                                   arguments: ["ref": target.ref, "token": token])
            found = try await devtools(view, "Runtime.evaluate", ["expression": find])
        }
        guard let objectId = (found["result"] as? [String: Any])?["objectId"] as? String else {
            throw AgentError("That isn't a file field.")
        }
        try await page.call("DOM.setFileInputFiles", ["files": paths, "objectId": objectId], session: target.frame?.session)
        _ = try? await page.call("Runtime.evaluate", ["expression": find + "?.removeAttribute('data-sill-pick')"], session: target.frame?.session)
        return ["uploaded": paths.map { ($0 as NSString).lastPathComponent }]
    }

    // MARK: passwords

    /// As Safari suggests them: three groups of six, letters and digits,
    /// joined by hyphens (about 71 bits), from the system's secure source.
    private static func strongPassword() -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func pick() -> Character {
            var byte: UInt8 = 0
            repeat { _ = SecRandomCopyBytes(kSecRandomDefault, 1, &byte) } while Int(byte) >= 256 - 256 % letters.count
            return letters[Int(byte) % letters.count]
        }
        var groups = (0..<3).map { _ in String((0..<6).map { _ in pick() }) }
        // At least one digit and one capital, as sites ask.
        groups[0] = String(groups[0].dropLast()) + "7"
        groups[2] = "K" + String(groups[2].dropFirst())
        return groups.joined(separator: "-")
    }

    /// Fills every visible new-password box (and a confirmation) and the
    /// account name before them, if empty. Answers how many it filled.
    private static let fillNewPassword = """
    const shown = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const set = (input, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      input.focus(); setter.call(input, value);
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const boxes = [...document.querySelectorAll('input[type=password]')].filter(shown);
    let n = 0;
    for (const box of boxes) { if (box.autocomplete !== 'current-password' || boxes.length === 1) { set(box, password); n++; } }
    if (boxes.length) {
      const all = [...document.querySelectorAll('input')].filter(shown);
      for (let j = all.indexOf(boxes[0]) - 1; j >= 0; j--) {
        const i = all[j];
        if (['text', 'email', ''].includes(i.type)) { if (!i.value) { set(i, user); n++; } break; }
      }
    }
    return n;
    """

    // MARK: DevTools: input and pictures that need no focus and no front

    @discardableResult
    private static func devtools(_ view: SillWebView, _ method: String, _ params: [String: Any] = [:],
                                 timeout: Double = 10) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            view.devtools(method, params: params) { result, error in
                guard once.claim() else { return }
                if let result { continuation.resume(returning: result as? [String: Any] ?? [:]) }
                else { continuation.resume(throwing: AgentError(error ?? "\(method) failed.")) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                continuation.resume(throwing: AgentError("\(method) took too long."))
            }
        }
    }

    private final class Once {
        private var done = false
        func claim() -> Bool { if done { return false }; done = true; return true }
    }

    /// A click as a mouse makes it (trusted events, hover first), sent into the page itself.
    private static func click(at x: Double, _ y: Double, in view: SillWebView, count: Int,
                              button: String = "left", hold: Double = 0, modifiers: Int = 0) async throws {
        let mask = ["left": 1, "right": 2, "middle": 4][button] ?? 1
        let name = mask == 1 ? "left" : mask == 2 ? "right" : "middle"
        try await devtools(view, "Input.dispatchMouseEvent", ["type": "mouseMoved", "x": x, "y": y, "modifiers": modifiers])
        for n in 1...count {
            let base: [String: Any] = ["x": x, "y": y, "button": name, "clickCount": n, "pointerType": "mouse", "modifiers": modifiers]
            try await devtools(view, "Input.dispatchMouseEvent", base.merging(["type": "mousePressed", "buttons": mask]) { $1 })
            // A long press: held down this long before letting go.
            if hold > 0 { try await Task.sleep(nanoseconds: UInt64(min(hold, 10) * 1e9)) }
            // The release is answered only once the page's handler returns: if
            // that opened a dialog, not until it's answered. Don't wait for it.
            try await untilDialog(view) {
                try await devtools(view, "Input.dispatchMouseEvent", base.merging(["type": "mouseReleased", "buttons": 0]) { $1 })
            }
            if view.openDialog != nil { return }
        }
    }

    /// Runs `work`, but stops waiting for it the moment the page opens a
    /// dialog (the work's answer only comes once the dialog is closed).
    private static func untilDialog(_ view: SillWebView, _ work: @escaping @MainActor () async throws -> Void) async throws {
        final class State { var finished = false; var failure: Error? }
        let state = State()
        Task { @MainActor in
            do { try await work() } catch { state.failure = error }
            state.finished = true
        }
        while !state.finished && view.openDialog == nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        if let failure = state.failure, view.openDialog == nil { throw failure }
    }

    private static let namedKeys: [String: (key: String, code: String, keyCode: Int, text: String?)] = [
        "enter": ("Enter", "Enter", 13, "\r"), "return": ("Enter", "Enter", 13, "\r"),
        "tab": ("Tab", "Tab", 9, nil), "escape": ("Escape", "Escape", 27, nil), "esc": ("Escape", "Escape", 27, nil),
        "backspace": ("Backspace", "Backspace", 8, nil), "delete": ("Delete", "Delete", 46, nil),
        "space": (" ", "Space", 32, " "),
        "arrowup": ("ArrowUp", "ArrowUp", 38, nil), "arrowdown": ("ArrowDown", "ArrowDown", 40, nil),
        "arrowleft": ("ArrowLeft", "ArrowLeft", 37, nil), "arrowright": ("ArrowRight", "ArrowRight", 39, nil),
        "pageup": ("PageUp", "PageUp", 33, nil), "pagedown": ("PageDown", "PageDown", 34, nil),
        "home": ("Home", "Home", 36, nil), "end": ("End", "End", 35, nil),
    ]

    /// Types each character as its own key press.
    private static func keystrokes(_ text: String, in view: SillWebView) async throws {
        for character in text {
            view.agentKeysUntil = Date.timeIntervalSinceReferenceDate + 2
            if character == "\n" { try await key("Enter", in: view); continue }
            let c = String(character)
            let code = c.unicodeScalars.count == 1 && c.unicodeScalars.first!.isASCII
                ? Int(c.uppercased().unicodeScalars.first!.value) : 0
            let event: [String: Any] = ["key": c, "text": c, "unmodifiedText": c, "windowsVirtualKeyCode": code]
            try await untilDialog(view) { try await devtools(view, "Input.dispatchKeyEvent", event.merging(["type": "keyDown"]) { $1 }) }
            if view.openDialog != nil { return }
            try await devtools(view, "Input.dispatchKeyEvent", ["type": "keyUp", "key": c, "windowsVirtualKeyCode": code])
        }
    }

    /// Gives the element the keyboard: a click for what only takes focus that way, else focus().
    private static func focus(_ target: Target, in view: SillWebView) async throws {
        if target.backend != nil { try await click(at: target.x, target.y, in: view, count: 1); return }
        if let frame = target.frame {
            try await click(at: target.x, target.y, in: view, count: 1)
            _ = try? await AgentPage.of(view).evaluate("window.__sillAgent.focus(\(json(target.inner)), false)", in: frame)
            return
        }
        _ = try await evaluate("return window.__sillAgent.focus(ref, false)", in: view, world: Web.world, arguments: ["ref": target.ref])
    }

    /// "Enter", "ArrowDown", "a", or a chord: "Meta+A", "Shift+Tab", "Ctrl+Enter".
    private static func key(_ name: String, in view: SillWebView) async throws {
        var parts = name.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        if name.hasSuffix("++") { parts = parts.filter { !$0.isEmpty } + ["+"] }
        guard let last = parts.last, !last.isEmpty else { throw AgentError("Missing \"key\".") }
        var modifiers = 0
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "alt", "option", "opt": modifiers |= 1
            case "ctrl", "control": modifiers |= 2
            case "meta", "cmd", "command": modifiers |= 4
            case "shift": modifiers |= 8
            default: throw AgentError("Unknown modifier \(modifier). Use Shift, Ctrl, Alt or Meta.")
            }
        }
        var event: [String: Any]
        if let named = namedKeys[last.lowercased()] {
            event = ["key": named.key, "code": named.code, "windowsVirtualKeyCode": named.keyCode]
            if let text = named.text, modifiers & 6 == 0 { event["text"] = text; event["unmodifiedText"] = text }
        } else if last.count == 1, let scalar = last.unicodeScalars.first {
            let lower = last.lowercased(), upper = last.uppercased()
            let character = modifiers & 8 != 0 ? upper : last
            let code = scalar.properties.isAlphabetic ? "Key\(upper)" : (CharacterSet.decimalDigits.contains(scalar) ? "Digit\(last)" : "")
            let keyCode = Int(upper.unicodeScalars.first!.value)
            event = ["key": character, "code": code, "windowsVirtualKeyCode": keyCode]
            if modifiers & 6 == 0 { event["text"] = character; event["unmodifiedText"] = lower }
            // On a Mac, ⌘ chords are editing commands, not text.
            if modifiers & 4 != 0, let command = ["a": "selectAll", "c": "copy", "v": "paste", "x": "cut", "z": "undo",
                                                  "b": "bold", "i": "italic", "u": "underline"][lower] {
                event["commands"] = [modifiers & 8 != 0 && lower == "z" ? "redo" : command]
            }
        } else {
            throw AgentError("Unknown key \(last). Use Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp/Down/Left/Right, PageUp, PageDown, Home, End, a single character, or a chord like Meta+A.")
        }
        event["modifiers"] = modifiers
        view.agentKeysUntil = Date.timeIntervalSinceReferenceDate + 2
        // ⌘C, ⌘X, ⌘V: the agent's own clipboard, never yours.
        let clipboardCommand = (event["commands"] as? [String])?.first.flatMap { ["copy", "cut", "paste"].contains($0) ? $0 : nil }
        let yours = clipboardCommand.map { _ in AgentClipboard.take() }
        if clipboardCommand == "paste" { AgentClipboard.lend() }
        let count = NSPasteboard.general.changeCount
        defer {
            if let yours, let clipboardCommand {
                Task { @MainActor in
                    if clipboardCommand == "paste" {
                        // The page reads it as the paste runs: a moment, then yours is back.
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    } else {
                        // Chromium writes a copy a little later: wait for it to land (up to 1 s).
                        for _ in 0..<100 where NSPasteboard.general.changeCount == count { try? await Task.sleep(nanoseconds: 10_000_000) }
                        AgentClipboard.keepAgents()
                    }
                    AgentClipboard.restore(yours)
                }
            }
        }
        try await untilDialog(view) {
            try await devtools(view, "Input.dispatchKeyEvent", event.merging(["type": event["text"] != nil ? "keyDown" : "rawKeyDown"]) { $1 })
        }
        if view.openDialog != nil { return }
        try await devtools(view, "Input.dispatchKeyEvent", event.merging(["type": "keyUp"]) { $1 }.filter { $0.key != "text" && $0.key != "commands" })
    }

    /// The page as it's drawn, never brought to the front: JPEG, scaled to `maxWidth` pixels.
    private static func screenshot(of view: SillWebView, maxWidth: Double, quality: Double,
                                   marks: [[String: Any]] = [], cssWidth: Double = 0) async throws -> [String: Any] {
        if view.pageHidden { view.insistShown() }
        let shot = try await devtools(view, "Page.captureScreenshot", ["format": "jpeg", "quality": 85, "optimizeForSpeed": true], timeout: 8)
        guard let base64 = shot["data"] as? String, let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw AgentError("The page couldn't be captured.") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(64, Int(maxWidth)),
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let image = width > Int(maxWidth) ? CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                                          : CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard var image else { throw AgentError("The page couldn't be captured.") }
        if !marks.isEmpty, cssWidth > 0, let marked = Self.mark(image, with: marks, scale: Double(image.width) / cssWidth) { image = marked }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            throw AgentError("The page couldn't be captured.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let scale = Double(image.width) / max(1, Double(view.bounds.width))
        return ["data": (out as Data).base64EncodedString(), "mimeType": "image/jpeg",
                "width": image.width, "height": image.height,
                "note": "Image pixels = CSS pixels × \(String(format: "%.2f", scale)); snapshot boxes are CSS pixels."]
    }

    /// Each element's box and ref drawn on the picture ("set of marks"): what
    /// the model sees maps straight onto what it can click.
    private static func mark(_ image: CGImage, with elements: [[String: Any]], scale: Double) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let palette: [NSColor] = [.systemBlue, .systemPink, .systemOrange, .systemGreen, .systemPurple, .systemTeal, .systemRed]
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        let font = NSFont.monospacedSystemFont(ofSize: max(9, 11 * min(scale, 1.4)), weight: .semibold)
        for (i, element) in elements.enumerated() {
            guard let ref = element["ref"] as? String, let box = element["box"] as? [String: Any] else { continue }
            let x = (box["x"] as? Double ?? 0) * scale, y = (box["y"] as? Double ?? 0) * scale
            let bw = (box["w"] as? Double ?? 0) * scale, bh = (box["h"] as? Double ?? 0) * scale
            let rect = CGRect(x: x, y: Double(h) - y - bh, width: bw, height: bh)   // CG's origin is the bottom
            guard rect.maxY > 0, rect.minY < Double(h), rect.width > 2, rect.height > 2 else { continue }
            let color = palette[i % palette.count]
            context.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.5)
            context.stroke(rect)
            let label = NSAttributedString(string: ref, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = label.size()
            let tag = CGRect(x: rect.minX, y: min(Double(h) - size.height - 2, rect.maxY), width: size.width + 6, height: size.height + 2)
            context.setFillColor(color.cgColor)
            context.fill(tag)
            label.draw(at: CGPoint(x: tag.minX + 3, y: tag.minY + 1))
        }
        return context.makeImage()
    }

    /// After an action, until the page has answered it, with no fixed pause:
    /// done once the page has changed and then held still for 60 ms (or 0.8 s
    /// after its first change, if it keeps ticking), or hasn't changed at all in
    /// 100 ms;
    /// with what the action asked the network for (suggestions, results) back,
    /// and a page it started loading readable. Animations don't count as
    /// change: style, class, svg and canvas are left out. At most 2.5 s beyond
    /// a page's arrival (10 s).
    private static func settle(_ tab: Tab, _ view: SillWebView, since: Date = Date()) async {
        let start = Date()
        await settleOnce(tab, view, since: since)
        // What this site's pace is, and whether a search went into the address: for the next plan.
        SiteNotes.shared.settled(tab, url: view.url, ms: Int(Date().timeIntervalSince(since) * 1000))
        _ = start
    }

    private static func settleOnce(_ tab: Tab, _ view: SillWebView, since: Date) async {
        let page = AgentPage.of(view)
        let start = Date()
        var deadline = start.addingTimeInterval(2.5)
        var firstChange: Date?
        try? await Task.sleep(nanoseconds: 16_000_000)   // a frame for the page's handlers to run
        while Date() < deadline {
            if view.openDialog != nil { return }
            let state = (try? await evaluate("return window.__sillAgent.state()", in: view, world: Web.world)) as? [String: Any]
            // No answer from the page and nothing loading (a dialog froze it, the script was refused): nothing to wait for.
            if state == nil, !view.isLoading { return }
            guard let state, readable(state["ready"] as? String, view) else {
                // A page on its way: wait for it (up to 10 s), then for it to settle.
                if Date().timeIntervalSince(start) < 10 { deadline = max(deadline, Date().addingTimeInterval(1)) }
                try? await Task.sleep(nanoseconds: 30_000_000)
                continue
            }
            let idle = state["idle"] as? Double ?? .infinity
            let elapsed = Date().timeIntervalSince(since) * 1000
            if !page.fetching(since: since) {
                if idle < elapsed {
                    // It answered: done once it holds still, or a moment after it first did if it keeps ticking.
                    let first = firstChange ?? Date()
                    firstChange = first
                    if idle >= 60 || Date().timeIntervalSince(first) > 0.8 { return }
                } else if elapsed >= 100 {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    /// Something to read: a new document parsed (its images and ads may still
    /// come), or the old one with no load pending.
    private static func readable(_ ready: String?, _ view: SillWebView) -> Bool {
        ready == "interactive" || (ready == "complete" && !view.isLoading)
    }

    /// Until the page can be read and acted on: parsed, not every last image and ad loaded.
    private static func waitForReadable(_ tab: Tab, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let view = tab.materialize()
        while Date() < deadline {
            if view.openDialog != nil { return }
            if let ready = try? await evaluate("return document.readyState", in: view, world: Web.world) as? String,
               readable(ready, view) { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw AgentError("Timed out after \(Int(timeout)) s waiting for the page to load.")
    }

    // MARK: helpers

    private static func evaluate(_ body: String, in view: SillWebView, world: WKContentWorld,
                                 arguments: [String: Any] = [:], timeout: Double = 6) async throws -> Any? {
        // A page waiting on its own dialog runs no script until it's answered.
        if let dialog = view.openDialog { throw dialogError(dialog) }
        // A page that navigates away mid-call (a click that loads a heavy page) may never answer:
        // never wait on it for ever.
        final class Once { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                guard !once.done else { return }
                once.done = true
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error):
                    // Sill's own "Can't open this page" (or a page between documents) has no agent script: say
                    // what the tab shows, not a script error.
                    let said = error.localizedDescription
                    if said.contains("reading 'locate'") || said.contains("__sillAgent") || said.contains("reading 'snapshot'") || said.contains("reading 'records'") {
                        let failed = view.tab?.displayTitle == "Can’t open this page"
                        continuation.resume(throwing: AgentError(failed
                            ? "This tab shows Sill's “Can’t open this page” (\(view.tab?.failedWith ?? "the site couldn't be reached")): nothing on it to act on. Open the address again, or another source."
                            : "The page is between documents (loading or reloading itself): look again in a moment."))
                    } else {
                        continuation.resume(throwing: AgentError("Script failed: \(said)"))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(throwing: AgentError("The page didn't answer within \(Int(timeout)) s (it may be loading a new page): look again."))
            }
        }
    }

    private static func sanitize(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return String(describing: value)
    }

    private static func waitForLoad(_ tab: Tab, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let view = tab.materialize()
        while Date() < deadline {
            if !view.isLoading,
               let state = try? await evaluate("return document.readyState", in: view, world: Web.world) as? String,
               state == "complete" { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AgentError("Timed out after \(Int(timeout)) s waiting for the page to load.")
    }

    private static func waitFor(selector: String?, text: String?, in view: SillWebView, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = try? await evaluate("return window.__sillAgent.present(selector, text)", in: view, world: Web.world,
                                            arguments: ["selector": selector ?? NSNull(), "text": text ?? NSNull()]) as? Bool
            if found == true { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw AgentError("Timed out after \(Int(timeout)) s waiting for \(selector ?? text ?? "it").")
    }

    /// What an action acts on: where on the page (CSS pixels of the
    /// viewport, what DevTools input takes), and what it is.
    struct Target {
        var ref: String
        var x: Double
        var y: Double
        var name: String
        var frame: AgentPage.Frame? = nil   // in a frame in another process
        var inner: String? = nil            // its ref inside that frame
        var backend: Int? = nil             // an accessibility-tree node (closed shadow root)
        var disabled = false
        var visible = true
        var coveredBy: [String: Any]? = nil
        var partial = false

        func mustBeClickable() throws {
            if disabled { throw AgentError("“\(name)” (\(ref)) is disabled: the page has turned it off. In a form, a required field or box may still be empty; among filters or options, the choices already made may leave nothing for it.") }
            if let cover = coveredBy {
                if let dialog = cover["dialog"] as? String {
                    let exits = (cover["exits"] as? [[String: Any]] ?? []).map { "“\($0["name"] as? String ?? "")” (\($0["ref"] as? String ?? ""))" }
                    throw AgentError("“\(name)” (\(ref)) is behind the open dialog “\(dialog)”. "
                        + (exits.isEmpty ? "Close it first (page_press Escape often does)." : "Close it first: \(exits.joined(separator: " or ")), or page_press Escape."))
                }
                if cover["overlay"] as? Bool == true {
                    let says = (cover["name"] as? String).flatMap { $0.isEmpty ? nil : " (it says “\($0)”)" } ?? ""
                    throw AgentError("“\(name)” (\(ref)) is under a page-wide overlay\(says): a menu, picker or banner left open. Close it first: page_press Escape often does.")
                }
                let what = (cover["name"] as? String).flatMap { $0.isEmpty ? nil : "“\(String($0.prefix(60)))”" } ?? "a \(cover["tag"] as? String ?? "layer")"
                let coverRef = (cover["ref"] as? String).map { " (\($0))" } ?? ""
                throw AgentError("“\(name)” (\(ref)) is covered by \(what)\(coverRef): a click there would land on that instead. Close or answer it first.")
            }
        }
    }

    /// The element named by ref, CSS selector or visible text, scrolled into
    /// view, checked for what a click there would reach. Refs never resolve to
    /// a lookalike: a ref whose element is gone is an error, not a guess. A
    /// selector or text is waited for (up to `wait` seconds, 3 by default) as
    /// pages render late.
    private static func locate(_ args: [String: Any], in view: SillWebView) async throws -> Target {
        let ref = args["ref"] as? String
        let page = AgentPage.of(view)
        // In a frame in another process.
        if let ref, ref.hasPrefix("f"), let colon = ref.firstIndex(of: ":"), let index = Int(ref.dropFirst().prefix(upTo: colon)) {
            let inner = String(ref[ref.index(after: colon)...])
            guard let frame = page.frame(index: index) else {
                throw AgentError("\(ref) is no longer on the page: its frame went away. Use the refs from the latest element list.")
            }
            let at = try await page.offset(of: frame, reveal: true)
            guard let found = try await page.evaluate("window.__sillAgent.locate(\(json(inner)), null, null)", in: frame) as? [String: Any] else {
                throw AgentError("\(ref) isn't in its frame any more.")
            }
            if found["gone"] != nil { throw AgentError("\(ref) is no longer on the page: it changed after the last element list. Use the refs from the latest answer.") }
            let at2 = try await page.offset(of: frame, reveal: false)   // the frame may have moved as it scrolled
            var t = target(from: found, ref: ref)
            t.x += at2.x; t.y += at2.y
            _ = at
            t.frame = frame
            t.inner = inner
            return t
        }
        // Inside a closed shadow root, by its accessibility node.
        if let ref, ref.hasPrefix("a"), let backend = Int(ref.dropFirst()) {
            guard let box = await page.box(of: backend, reveal: true) else {
                throw AgentError("\(ref) is no longer on the page. Use the refs from the latest element list.")
            }
            return Target(ref: ref, x: box.midX, y: box.midY, name: ref, backend: backend)
        }
        let byName = ref == nil
        // A step's own settle has already waited for the page to answer: a short wait covers late renders.
        let deadline = Date().addingTimeInterval(byName ? (args["wait"] as? Double ?? 1.5) : 0)
        let started = Date()
        while true {
            if let dialog = view.openDialog { throw dialogError(dialog) }
            let found = try await evaluate("return window.__sillAgent.locate(ref, selector, text, editable, scope)", in: view, world: Web.world, arguments: [
                "ref": ref ?? NSNull(), "selector": args["selector"] as? String ?? NSNull(), "text": args["text"] as? String ?? NSNull(),
                "editable": args["editable"] as? Bool ?? false, "scope": args["in"] as? String ?? NSNull(),
            ]) as? [String: Any]
            if let found, let options = found["ambiguous"] as? [[String: Any]] {
                let list = options.map { "\($0["name"] as? String ?? "") (\($0["ref"] as? String ?? ""))" }.joined(separator: ", ")
                throw AgentError("“\(args["text"] as? String ?? "")” matches \(options.count) things: \(list). Use a ref, or say where with \"in\" (e.g. \"in\": \"December 2026\").")
            }
            if let found, found["gone"] != nil {
                throw AgentError("\(ref ?? "That element") is no longer on the page: it changed after the last element list. Use the refs from the latest answer.")
            }
            if let found, found["ref"] != nil, found["visible"] as? Bool != false || Date() >= deadline {
                return target(from: found, ref: nil)
            }
            // Not there, and the page has held its shape a while (nothing still arriving): it won't come, so say so
            // now rather than at the deadline. A name that's close but not the page's own fails in a third of a second.
            var settledAbsent = false
            if byName, args["wait"] == nil, Date().timeIntervalSince(started) > 0.3,
               let state = (try? await evaluate("return window.__sillAgent.state()", in: view, world: Web.world)) as? [String: Any],
               // ...and the agent's last action was a while ago: right after a click, a page may still draw on a timer.
               (state["still"] as? Double ?? 0) >= 800, (state["sinceAct"] as? Double ?? 0) >= 1500,
               !view.isLoading, !AgentPage.of(view).fetching(since: .distantPast) {
                settledAbsent = true
            }
            if Date() >= deadline || settledAbsent {
                let near = await closest(to: args["text"] as? String, in: view)
                throw AgentError(byName ? "Nothing on the page matches \((args["selector"] ?? args["text"]).map { "“\($0)”" } ?? "that").\(near)"
                                        : "No element matched. Use page_read for refs.")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    /// For a text that matched nothing: the elements nearest to it by words, so
    /// the next try is right without a fresh look at the page.
    private static func closest(to text: String?, in view: SillWebView) async -> String {
        let words = { (s: String) in Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }) }
        let elements = (try? await evaluate("return window.__sillAgent.snapshot(false)", in: view, world: Web.world)) as? [[String: Any]] ?? []
        let named = elements.compactMap { e -> (ref: String, label: String)? in
            guard let ref = e["ref"] as? String, let name = e["name"] as? String, !name.isEmpty else { return nil }
            return (ref, "\(e["role"] as? String ?? "") “\(name.prefix(60))”")
        }
        guard !named.isEmpty else { return " The page has nothing to act on in view: page_read text=true reads it, or scroll." }
        let wanted = words(text ?? "")
        let ranked = named.map { ($0, words($0.label).intersection(wanted).count) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        let shown = (ranked.isEmpty ? Array(named.prefix(12)) : Array(ranked.prefix(6))).map { "\($0.label) (\($0.ref))" }
        return (ranked.isEmpty ? " On the page now: " : " Closest: ") + shown.joined(separator: ", ") + "."
    }

    private static func target(from found: [String: Any], ref: String?) -> Target {
        let label = [(found["role"] as? String) ?? "", (found["name"] as? String) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        var t = Target(ref: ref ?? (found["ref"] as? String ?? ""), x: found["x"] as? Double ?? 0, y: found["y"] as? Double ?? 0, name: label)
        t.disabled = found["disabled"] as? Bool ?? false
        t.visible = found["visible"] as? Bool ?? true
        t.coveredBy = found["coveredBy"] as? [String: Any]
        t.partial = found["partial"] as? Bool ?? false
        return t
    }

    private static func json(_ value: Any?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    private static func dialogError(_ dialog: [String: String]) -> AgentError {
        AgentError("The page has a \(dialog["kind"] ?? "dialog") open: “\(dialog["message"] ?? "")”. Answer it with page_dialog (accept or dismiss) first.")
    }

    /// Types `text` into the target as a keyboard would, then reads it back.
    private static func type(_ text: String, into target: Target, clear: Bool, in view: SillWebView) async throws -> (ok: Bool, value: String?, into: String?) {
        let page = AgentPage.of(view)
        func run(_ call: String) async throws -> Any? {
            if let frame = target.frame { return try await page.evaluate("window.__sillAgent.\(call)", in: frame) }
            return try await evaluate("return window.__sillAgent.\(call)", in: view, world: Web.world)
        }
        let baseRef = target.inner ?? target.ref
        if target.backend != nil {
            // Inside a closed shadow root: click to focus, then type.
            try await click(at: target.x, target.y, in: view, count: 1)
            if clear { try? await key("Meta+A", in: view) }
            try await devtools(view, "Input.insertText", ["text": text])
            return (true, nil, nil)
        }
        var ref = baseRef
        var into: String?
        if target.frame == nil {
            // A combobox or popup trigger: clicked for real first, as a person would, so its field opens.
            if let prep = try? await run("prepType(\(json(ref)))") as? [String: Any], prep["click"] as? Bool == true {
                try await click(at: target.x, target.y, in: view, count: 1)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            // The page put the focus in a field of its own (a popup's search box): type there.
            if let moved = try? await run("retarget(\(json(ref)))") as? [String: Any], let to = moved["ref"] as? String {
                ref = to
                into = to
            }
        }
        let kind = try await run("valueKind(\(json(ref)))") as? String ?? ""
        if ["date", "time", "datetime-local", "month", "week", "color", "range"].contains(kind) {
            let ok = try await run("setValue(\(json(ref)), \(json(text)))") as? Bool ?? false
            if !ok { throw AgentError("“\(target.name)” didn't take “\(text)”. \(kind == "date" ? "Dates go as YYYY-MM-DD." : "")") }
            return (true, text, into)
        }
        // A frame in another process gets the keyboard by being clicked first.
        if target.frame != nil { try await click(at: target.x, target.y, in: view, count: 1) }
        let focused = try await run("focus(\(json(ref)), \(clear))") as? Bool ?? false
        if focused {
            if text.isEmpty { if clear { try? await key("Backspace", in: view) } }
            else if text.count <= 400 {
                // Key by key, as fingers do: keydown, the character, keyup. Pages
                // that listen for keys (suggestions, shortcuts, games) see them.
                try await keystrokes(text, in: view)
            } else {
                _ = try? await devtools(view, "Input.insertText", ["text": text])
            }
        }
        var value = try await run("typed(\(json(ref)))") as? String
        let expected = clear ? text : nil
        let took = { (v: String?) -> Bool in
            guard let v else { return false }
            if let expected { return v == expected || v.replacingOccurrences(of: " ", with: "") == expected.replacingOccurrences(of: " ", with: "") }
            return v.hasSuffix(text)
        }
        if !took(value) {
            // The page didn't take keystrokes there: set it as a script would.
            let set = try await run("type(\(json(ref)), \(json(text)), \(clear))") as? Bool ?? false
            if !set && !focused { throw AgentError("“\(target.name)” isn't something to type into. Click it first if it opens a field, then type into that.") }
            value = try await run("typed(\(json(ref)))") as? String
        }
        let isPassword = kind == "password"
        return (took(value), isPassword ? nil : value, into)
    }

    /// An action's answer, with what it set off: a dialog, a new tab.
    private static func outcome(_ answer: [String: Any], _ view: SillWebView, since: Date) -> [String: Any] {
        var answer = answer
        answer["url"] = view.url?.absoluteString ?? ""
        // The page's own requests that this action set off and that failed: a search that can't run says so.
        let failed = AgentPage.of(view).failedRequests(since: since.addingTimeInterval(-0.1))
        if !failed.isEmpty { answer["failedRequests"] = failed }
        if let dialog = view.openDialog { answer["dialog"] = dialog }
        if let opener = view.tab, let adopted = adoptedFrom[ObjectIdentifier(opener)], adopted.at >= since, let browser = browser(of: adopted.tab) {
            remember(adopted.tab)
            answer["opened"] = describe(adopted.tab, in: browser)
        }
        return answer
    }
}

/// The agent's clipboard, kept apart from yours: copying in a page hands
/// what was copied to the agent, and your clipboard is put straight back.
@MainActor
enum AgentClipboard {
    typealias Contents = [[NSPasteboard.PasteboardType: Data]]
    private static var agents: Contents = []

    /// What's on the clipboard now, to give back later.
    static func take() -> Contents {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    /// What the page just copied: the agent's now.
    static func keepAgents() { agents = take() }

    /// Text the agent wants to paste: lines and tabs, so a spreadsheet puts each
    /// piece in its own row and column, as it would yours.
    static func set(text: String, html: String?) {
        var item: [NSPasteboard.PasteboardType: Data] = [.string: Data(text.utf8)]
        if let html { item[.html] = Data(html.utf8) }
        agents = [item]
    }

    /// For a paste: the agent's clipboard, briefly.
    static func lend() { put(agents) }

    static func restore(_ contents: Contents) { put(contents) }

    private static func put(_ contents: Contents) {
        let board = NSPasteboard.general
        board.clearContents()
        let items = contents.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}

// MARK: - The page side

enum AgentScript {
    /// Runs in Sill's own world: refs for interactive elements, and the
    /// actions on them. Never reads the value of a password field.
    static let source = #"""
    (() => {
      if (window.__sillAgent && window.__sillAgent.v === 34) return;
      const refs = new Map();
      const ids = new WeakMap();
      let next = 1;
      const refOf = (el) => {
        let ref = ids.get(el);
        if (!ref) { ref = 'e' + (next++); ids.set(el, ref); }
        refs.set(ref, new WeakRef(el));
        return ref;
      };
      const find = (ref) => { const w = refs.get(ref); const el = w && w.deref(); return el && el.isConnected ? el : null; };
      const known = (ref) => refs.has(ref);
      const style = (el) => el.ownerDocument.defaultView.getComputedStyle(el);
      const seen = (el) => {
        const r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) return false;
        // Put off the page on purpose (left or above it, the "visually hidden" trick): not seen by anyone.
        if (r.right <= 0 || r.bottom + (el.ownerDocument.defaultView.scrollY || 0) <= 0) return false;
        const s = style(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) > 0.01;
      };
      const interactive = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=option],[role=switch],[role=combobox],[role=textbox],[role=searchbox],[role=slider],[role=spinbutton],[role=treeitem],[role=gridcell],[contenteditable=""],[contenteditable=true],[onclick],[draggable=true],[tabindex]:not([tabindex="-1"])';
      const clean = (t) => String(t || '').replace(/\s+/g, ' ').trim();
      const byIds = (el, attr) => clean((el.getAttribute(attr) || '').split(/\s+/).map((id) => {
        const root = el.getRootNode(); const t = root.getElementById ? root.getElementById(id) : null; return t ? t.innerText || t.textContent : '';
      }).join(' '));
      // The words a person sees in it: text put off the page or squeezed to a pixel (copies kept for screen
      // readers, like a price written twice) is left out, so names read once.
      // Its words as a screen reader hears them: what the page marked aria-hidden (a price drawn in pieces
      // beside its spoken copy, icons) is left out, so a name reads once and whole.
      const shownText = (el) => {
        // innerText, never raw textContent: a <noscript> fallback's markup isn't words anyone sees.
        const all = el.innerText || (el.querySelector && el.querySelector('noscript') ? '' : el.textContent) || '';
        if (all.length > 400 || !el.querySelector || !el.querySelector('[aria-hidden=true]')) return all;
        const parts = [];
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        for (let n = walker.nextNode(); n; n = walker.nextNode()) {
          const p = n.parentElement;
          if (!p || p.closest('[aria-hidden=true]') || ['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(p.tagName)) continue;
          const t = n.textContent.trim(); if (t) parts.push(t);
        }
        // A phrase said twice in a row ("List: AED 249.00 List: AED 249.00"): once.
        const heard = parts.join(' ').replace(/(.{6,60}?)(?:\s+\1)+/g, '$1');
        return heard || all;
      };
      const name = (el) => {
        const label = el.getAttribute('aria-label') || byIds(el, 'aria-labelledby')
          || (el.labels && el.labels[0] && el.labels[0].innerText) || el.getAttribute('alt') || el.getAttribute('title')
          || el.getAttribute('placeholder') || (el.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(el.type) ? el.value : '')
          || (el.tagName === 'IFRAME' ? '' : shownText(el));
        let named = clean(label).slice(0, 120);
        // Named only by its placeholder ("Any date"): the labelled group around it says which.
        if (named && named === clean(el.getAttribute('placeholder')) && !el.getAttribute('aria-label')) {
          const group = el.closest('[role=group][aria-label], fieldset');
          const said = group && (group.getAttribute('aria-label') || (group.querySelector('legend') || {}).innerText);
          if (said && !clean(said).includes(named)) named = clean(said).slice(0, 80) + ' — ' + named;
        }
        return named;
      };
      const role = (el) => el.getAttribute('role') || ({ A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', SUMMARY: 'button' }[el.tagName])
        || (el.tagName === 'INPUT' ? (['checkbox', 'radio', 'submit', 'button', 'range', 'file', 'reset'].includes(el.type) ? (['submit', 'reset'].includes(el.type) ? 'button' : el.type)
            : ['date', 'time', 'datetime-local', 'month', 'week', 'color'].includes(el.type) ? el.type : 'textbox')
            : (el.isContentEditable ? 'textbox' : (clickables.has(el) ? 'clickable' : 'generic')));
      // What a person sees of it: itself, or for a visually hidden checkbox or radio, its label.
      const face = (el) => {
        if (seen(el)) return el;
        if (el.labels && el.labels.length && seen(el.labels[0]) && ['checkbox', 'radio', 'file'].includes(el.type)) return el.labels[0];
        // A control drawn invisible over its own look (many shops' buttons, styled toggles and file pickers):
        // the person sees its wrapper and clicks there, which reaches the control on top.
        const r = el.getBoundingClientRect();
        if (r.width >= 4 && r.height >= 4) {
          const s = style(el);
          if (s.display !== 'none' && s.visibility !== 'hidden' && Number(s.opacity) <= 0.01) {
            for (let p = el.parentElement, d = 0; p && d < 3; p = p.parentElement, d++) {
              if (!seen(p)) continue;
              const pr = p.getBoundingClientRect();
              if (pr.width * pr.height <= r.width * r.height * 4 + 400) return el;   // the look it sits on, not the whole page
            }
          }
        }
        return null;
      };
      // Every element, through open shadow roots and same-origin frames, with
      // the offset that turns its frame's coordinates into the page's.
      const walk = (root, dx, dy, visit) => {
        const stack = [root];
        while (stack.length) {
          const node = stack.pop();
          const kids = node.children || [];
          for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
          if (node.shadowRoot) stack.push(node.shadowRoot);
          if (node.nodeType !== 1) continue;
          if (visit(node, dx, dy) === false) return;
          if (node.tagName === 'IFRAME' || node.tagName === 'FRAME') {
            let doc = null; try { doc = node.contentDocument; } catch (_) {}
            if (doc && doc.documentElement) {
              const r = node.getBoundingClientRect(), s = style(node);
              walk(doc.documentElement, dx + r.left + node.clientLeft + parseFloat(s.paddingLeft), dy + r.top + node.clientTop + parseFloat(s.paddingTop), visit);
            }
          }
        }
      };
      const offsets = new WeakMap();   // element → its frame's offset, from the last walk
      const vaulted = new WeakSet();   // fields Sill filled from the vault: their value is never shown
      const metas = new Map();         // ref → its role and name when last listed, to find it again after a re-render
      const describe = (el, f, dx, dy) => {
        const r = f.getBoundingClientRect();
        const item = { ref: refOf(el), role: role(el), name: name(el), tag: el.tagName.toLowerCase(),
          box: { x: Math.round(r.left + dx), y: Math.round(r.top + dy), w: Math.round(r.width), h: Math.round(r.height) } };
        if (el.href) item.href = el.href;
        // Site furniture: a link in the navigation or the footer (they're listed by name only).
        if (el.tagName === 'A' || el.getAttribute('role') === 'link') {
          const reg = el.closest('nav,[role=navigation],footer,[role=contentinfo]');
          if (reg && !reg.closest('main,[role=main],article')) item.region = reg.matches('footer,[role=contentinfo]') ? 'footer' : 'nav';
        }
        if (el.type) item.type = el.type;
        if (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName) && el.type !== 'password' && !['checkbox', 'radio', 'submit', 'button', 'reset'].includes(el.type)) item.value = vaulted.has(el) ? '(filled from the vault)' : String(el.value).slice(0, 200);
        if (el.type === 'password') item.value = el.value ? '(hidden)' : '';
        if ('checked' in el && (el.type === 'checkbox' || el.type === 'radio')) item.checked = el.checked;
        const ac = el.getAttribute('aria-checked'); if (ac === 'true' || ac === 'false') item.checked = ac === 'true';
        // A dropdown says what it shows, not its option's internal value ("29" for Idaho).
        if (el.tagName === 'SELECT' && el.selectedIndex >= 0 && el.options[el.selectedIndex]) item.value = clean(el.options[el.selectedIndex].text).slice(0, 120) || item.value;
        // Toggles and the current item say so: a filter that's on, the page you're on.
        const ap = el.getAttribute('aria-pressed'); if (ap === 'true' || ap === 'false') item.checked = ap === 'true';
        const acur = el.getAttribute('aria-current'); if (acur && acur !== 'false') item.selected = true;
        const ae = el.getAttribute('aria-expanded'); if (ae) item.expanded = ae === 'true';
        const as = el.getAttribute('aria-selected'); if (as === 'true') item.selected = true;
        if (el.disabled || el.getAttribute('aria-disabled') === 'true') item.disabled = true;
        // A field the page says is wrong, with what it says about it.
        if (el.getAttribute('aria-invalid') === 'true' || (el.matches && el.matches(':user-invalid'))) {
          item.invalid = true;
          const why = byIds(el, 'aria-describedby') || byIds(el, 'aria-errormessage') || el.validationMessage || '';
          if (why) item.error = why.slice(0, 160);
        }
        if (el.getRootNode().activeElement === el || document.activeElement === el) item.focused = true;
        if (el.tagName === 'IFRAME') item.frame = true;
        // A slider's range, so a value can be typed straight in.
        if (el.type === 'range' || el.getAttribute('role') === 'slider') {
          item.min = el.min || el.getAttribute('aria-valuemin') || ''; item.max = el.max || el.getAttribute('aria-valuemax') || '';
          if (!item.value) item.value = el.getAttribute('aria-valuetext') || el.getAttribute('aria-valuenow') || '';
        }
        if (metas.size > 3000) metas.clear();
        metas.set(item.ref, { role: item.role, name: item.name });
        return item;
      };
      const all = (fn) => { const out = []; walk(document.documentElement, 0, 0, (el, dx, dy) => { offsets.set(el, [dx, dy]); return fn(el, dx, dy, out); }); return out; };
      // Things the page made clickable without saying so (a div with a click handler): found by the
      // pointer cursor the page gives them, outermost only, at the last look.
      let clickables = new WeakSet();
      const matches = (el) => { try { return el.matches(interactive) || clickables.has(el); } catch (_) { return false; } };
      const deepQuery = (selector) => { let hit = null; walk(document.documentElement, 0, 0, (el, dx, dy) => { offsets.set(el, [dx, dy]); try { if (el.matches(selector)) { hit = el; return false; } } catch (_) { return false; } }); return hit; };
      let lastAmbiguous = null, lastScore = 0, lastClicked = null;
      const skipRec = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'SELECT', 'NAV', 'FOOTER']);
      // The page's repeated records (result cards, rows): the biggest set of siblings that look alike and carry text.
      const recordSet = () => {
        let best = null, bestScore = 0;
          walk(document.body || document.documentElement, 0, 0, (el) => {
          if (el.childElementCount < 3 || skipRec.has(el.tagName)) return;
          const groups = new Map();
          // Alike = same tag and the classes most of the siblings share (one card's extra class doesn't split the set).
          const freq = new Map();
          for (const k of el.children) for (const c of k.classList) freq.set(c, (freq.get(c) || 0) + 1);
          const common = (k) => [...k.classList].filter((c) => freq.get(c) * 2 >= el.childElementCount).sort().join('.');
          for (const k of el.children) {
            // Only what's drawn: scripts holding data, styles and hidden templates are never records.
            if (skipRec.has(k.tagName) || k.tagName === 'LINK' || k.tagName === 'META' || !k.getClientRects().length) continue;
            const sig = k.tagName + '.' + common(k);
            const g = groups.get(sig); if (g) g.push(k); else groups.set(sig, [k]);
          }
          for (const ks of groups.values()) {
            if (ks.length < 3) continue;
            // A form's rows aren't records: fields to fill stay fields.
            if (ks.slice(0, 6).some((k) => k.querySelector('input:not([type=hidden]):not([type=submit]):not([type=button]):not([type=checkbox]):not([type=radio]), textarea, select'))) continue;
            const sample = ks.slice(0, 6).map((k) => clean(k.innerText).length);
            const avg = sample.reduce((a, b) => a + b, 0) / sample.length;
            if (avg < 12) continue;
            const score = ks.length * Math.min(avg, 400);
            if (score > bestScore) { bestScore = score; best = ks; }
          }
        });
        return best;
      };
      // A frame, or 50 ms if the page isn't drawing (a tab in the background can stop drawing): never a wait for ever.
      const frame = () => new Promise((r) => { let done = false; const go = () => { if (!done) { done = true; r(); } };
        requestAnimationFrame(go); setTimeout(go, 50); });
      const deepActive = () => { let a = document.activeElement; while (a && a.shadowRoot && a.shadowRoot.activeElement) a = a.shadowRoot.activeElement; return a; };
      // Where a control sits, for ones that can't be told apart by name ("26" in two months'
      // calendars, "Edit" on every row): the nearest container that says what it is.
      const within = (el, own) => {
        const up = (n) => n && (n.parentElement || (n.getRootNode() && n.getRootNode().host));
        // A date the page keeps on it or its cell (data-iso="2026-12-26", datetime=…): the plainest answer.
        for (let d = el, i = 0; d && i < 3; d = up(d), i++) {
          if (!d.attributes) continue;
          for (const a of d.attributes) if ((a.name.startsWith('data-') || a.name === 'datetime') && /^\d{4}-\d{2}-\d{2}/.test(a.value)) return a.value.slice(0, 25);
        }
        let n = up(el);
        for (let depth = 0; n && n !== document.body && depth < 7; depth++, n = up(n)) {
          const label = n.getAttribute('aria-label') || byIds(n, 'aria-labelledby');
          if (label && clean(label) !== own) return clean(label).slice(0, 60);
          // A heading, caption or legend inside it, before the control.
          // The nearest one before it: a panel of filters is often flat, a heading then its options, then the next.
          let head = null;
          for (const h of n.querySelectorAll(':scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > h5, :scope > h6, :scope > caption, :scope > legend, :scope > [role=heading], :scope h2, :scope h3, :scope [role=heading], :scope caption')) {
            if (contains(h, el) || !(h.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING)) continue;
            if (!head || (head.compareDocumentPosition(h) & Node.DOCUMENT_POSITION_FOLLOWING)) head = h;
          }
          if (head) {
            const t = clean(head.innerText); if (t && t !== own) return t.slice(0, 60);
          }
          // A short line of text that opens the container ("December 2026").
          if (n.childElementCount >= 2) {
            for (const k of n.children) {
              if (contains(k, el)) break;
              if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(k.tagName) || matches(k) || k.querySelector(interactive)) continue;
              const t = clean(k.innerText);
              if (t.length >= 3 && t.length <= 40 && t !== own) return t;
            }
          }
        }
        return '';
      };
      const typable = (el) => (el.tagName === 'INPUT' && !['checkbox', 'radio', 'submit', 'button', 'reset', 'file', 'image', 'hidden'].includes(el.type))
        || el.tagName === 'TEXTAREA' || el.isContentEditable;
      // `editable`: only what can be typed into, the focused one first (a popup's search box shares its trigger's name).
      // Best match by name: exact; then the words as whole words ("Depart" is in "Depart: Thu",
      // not in "Departure"); then anywhere. Ties go to the first on the page.
      const escape = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      // Everything that says where an element sits: its containers' labels, headings, captions, the
      // short line that opens a container ("December 2026"), dates kept on it. For "in" scopes.
      const placeOf = (el) => {
        const up = (n) => n && (n.parentElement || (n.getRootNode() && n.getRootNode().host));
        const parts = [];
        for (let n = el, d = 0; n && n !== document.body && d < 12; n = up(n), d++) {
          if (!n.getAttribute) continue;
          parts.push(n.getAttribute('aria-label') || '', byIds(n, 'aria-labelledby'), n.getAttribute('title') || '');
          for (const a of n.attributes) if (a.name.startsWith('data-') && /\d{4}-\d{2}/.test(a.value)) parts.push(a.value);
          if (n !== el && n.querySelector) {
            const head = n.querySelector(':scope > h1, :scope > h2, :scope > h3, :scope > h4, :scope > legend, :scope > caption, :scope > [role=heading]');
            if (head && !contains(head, el)) parts.push(head.innerText || '');
            const f = n.firstElementChild;
            if (f && !contains(f, el) && n.childElementCount >= 2 && !['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE'].includes(f.tagName)) { const t = clean(f.innerText); if (t.length <= 40) parts.push(t); }
          }
        }
        return parts.join(' | ').toLowerCase();
      };
      const inScope = (el, scope) => !scope || placeOf(el).includes(clean(scope).toLowerCase());
      // Several things share a name: the one in what's open in front (a dialog, a list of suggestions,
      // a popover), or the one a click would reach, if that leaves one.
      const frontmost = (els) => {
        const front = els.filter((el) => el.closest('[role=dialog],[aria-modal=true],dialog[open],[role=listbox],[popover],[role=menu]'));
        if (front.length === 1) return front[0];
        const reachable = els.filter((el) => { const f = face(el); if (!f) return false; const r = f.getBoundingClientRect();
          if (r.bottom < 0 || r.top > innerHeight) return false; const hit = hitAt(f.ownerDocument, r.left + r.width / 2, r.top + r.height / 2); return reaches(el, f, hit); });
        return reachable.length === 1 ? reachable[0] : null;
      };
      let lastScope = null;
      // Grids (spreadsheets, data grids): each cell has an address (B2) from its label, its row and column
      // indices, or its place in the rows; cells are found by that address.
      const colName = (i) => { let s = ''; for (i++; i > 0; i = Math.floor((i - 1) / 26)) s = String.fromCharCode(65 + (i - 1) % 26) + s; return s; };
      const cellAddress = (cell, grid) => {
        const label = clean(cell.getAttribute('aria-label') || '');
        if (/^[A-Z]{1,3}\d{1,6}$/.test(label)) return label;
        const ci = +cell.getAttribute('aria-colindex'), row = cell.closest('[role=row]'), ri = +(row && row.getAttribute('aria-rowindex'));
        if (ci && ri) return colName(ci - 1) + ri;
        if (row && grid) {
          const rows = [...grid.querySelectorAll('[role=row]')].filter((r) => r.closest('[role=grid],[role=treegrid]') === grid);
          const cells = [...row.children].filter((c) => /^(gridcell|cell|columnheader|rowheader)$/.test(c.getAttribute('role') || ''));
          const hasRowHeader = cells[0] && cells[0].getAttribute('role') === 'rowheader';
          const c = cells.indexOf(cell) - (hasRowHeader ? 1 : 0);
          if (c >= 0) return colName(c) + (rows.indexOf(row) + 1);
        }
        return '';
      };
      const cellByAddress = (addr) => {
        for (const grid of document.querySelectorAll('[role=grid],[role=treegrid]')) {
          for (const cell of grid.querySelectorAll('[role=gridcell],[role=cell]')) if (cellAddress(cell, grid) === addr) return cell;
        }
        return null;
      };
      const byText = (text, editable) => {
        // A cell by its address ("B2"), when the page has a grid.
        if (!editable && /^[A-Z]{1,3}\d{1,6}$/.test(clean(text))) { const cell = cellByAddress(clean(text)); if (cell) return cell; }
        const scope = lastScope;
        const want = clean(text).toLowerCase();
        const whole = new RegExp('(^|[^\\p{L}\\p{N}])' + escape(want) + '($|[^\\p{L}\\p{N}])', 'u');
        let score = 0, focused = null, tied = [];
        walk(document.documentElement, 0, 0, (el, dx, dy) => {
          offsets.set(el, [dx, dy]);
          if (!matches(el) || !face(el)) return;
          if (editable && !typable(el)) return;
          if (scope && !inScope(el, scope)) return;
          const n = name(el).toLowerCase();
          const hit = n === want ? 3 : whole.test(n) ? 2 : n.includes(want) ? 1 : 0;
          if (!hit) return;
          if (editable && (el.getRootNode().activeElement === el || document.activeElement === el) && !focused) focused = el;
          if (hit > score) { score = hit; tied = [el]; } else if (hit === score) tied.push(el);
        });
        if (focused) return focused;
        // One thing, or nested parts of one thing (a group and its field): that. Otherwise it's a guess: say so.
        const apart = tied.filter((el) => !tied.some((other) => other !== el && contains(other, el)));
        if (apart.length > 1) { const one = frontmost(apart); if (one) { lastScore = score; return one; } }
        // Several hold the words, but one is mostly those words ("…, Round Trip" beside deal cards that mention
        // "Round Trip" among much else): that one is what a person means. Close ones stay a question.
        if (apart.length > 1 && score < 3) {
          const cover = apart.map((el) => ({ el, c: want.length / Math.max(want.length, name(el).length) })).sort((a, b) => b.c - a.c);
          if (cover[0].c >= 0.3 && cover[0].c >= 2 * cover[1].c) { lastScore = score; return cover[0].el; }
        }
        if (apart.length > 1) {
          lastAmbiguous = apart.slice(0, 6).map((el) => { const n = name(el).slice(0, 70), w = within(el, n); return { ref: refOf(el), role: role(el), name: w ? n + ' (in ' + w + ')' : n }; });
          return null;
        }
        lastScore = score;
        if (tied.length) return apart[0] || tied[0];
        // Named by its kind ("combobox", "search box"): the one field of that kind on the page.
        if (/^(combobox|textbox|searchbox|search box|search field|text field|input)$/.test(want)) {
          const kinds = []; walk(document.documentElement, 0, 0, (el, dx, dy) => { offsets.set(el, [dx, dy]); if (typable(el) && face(el) && matches(el)) kinds.push(el); });
          const fit = kinds.filter((el) => want.startsWith('search') ? /search/i.test(role(el) + ' ' + (el.type || '') + ' ' + name(el)) : true);
          if (fit.length === 1) return fit[0];
        }
        if (editable) return null;
        // Not a control: the smallest visible element whose own text it is (a card, a label, a drop zone).
        let plain = null;
        walk(document.documentElement, 0, 0, (el, dx, dy) => {
          offsets.set(el, [dx, dy]);
          if (!seen(el) || ['HTML', 'BODY', 'SCRIPT', 'STYLE'].includes(el.tagName)) return;
          const own = clean([...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join(' ')).toLowerCase();
          if (own && (own === want || own.includes(want)) && inScope(el, scope)) plain = el;
        });
        return plain;
      };
      // The element a click at (x, y) in its frame would reach, through shadow roots.
      const hitAt = (doc, x, y) => {
        let hit = doc.elementFromPoint(x, y);
        while (hit && hit.shadowRoot) { const inner = hit.shadowRoot.elementFromPoint(x, y); if (!inner || inner === hit) break; hit = inner; }
        return hit;
      };
      const contains = (a, b) => { for (let n = b; n; n = n.parentNode || n.host) if (n === a) return true; return false; };
      // What lies over a field is its own face (a custom dropdown's placeholder or chosen value drawn on top): a
      // small wrapper they share holds no other control, so a click there reaches the field.
      const ownSkin = (el, hit) => {
        if (!hit || hit === el) return false;
        for (let p = el.parentElement, d = 0; p && d < 3; p = p.parentElement, d++) {
          if (!contains(p, hit)) continue;
          const controls = [...p.querySelectorAll(interactive)].filter((c) => c !== el && !contains(c, el) && !contains(el, c));
          return controls.length === 0;
        }
        return false;
      };
      // Only the element itself, what's inside it, or its label: a hit on something
      // holding it (a scroll box under its overlay scrollbar) is a miss.
      const reaches = (el, f, hit) => hit && (contains(el, hit) || contains(f, hit) || (el.labels && [...el.labels].some((l) => contains(l, hit))));
      const set = (el, value) => {
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : el.tagName === 'SELECT' ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
      };
      // What frames the controls: headings, and what the page says out loud (alerts, live regions).
      const context = (el) => {
        if (/^H[1-3]$/.test(el.tagName) || el.getAttribute('role') === 'heading') return 'heading';
        // Announcements only: role=alert or an assertive region. Polite regions mostly hold
        // a control's current value ("Round trip"), which isn't news.
        const r = el.getAttribute('role');
        if (r === 'alert' || r === 'alertdialog' || el.getAttribute('aria-live') === 'assertive') return 'alert';
        return null;
      };
      window.__sillAgent = {
        v: 34,
        // The page as a person sees it, in reading order: headings, the text around the
        // controls (prices, results, messages), every control (including ones made clickable
        // only by script), what draws itself (canvas, maps, video), and what scrolls on its own.
        // Controls something else is on top of are marked. Near the view unless all_.
        snapshot(all_) {
          const t0 = performance.now();
          const H = innerHeight, W = innerWidth;
          const near = (top, h, below) => all_ || (top + h > -200 && top < H + below);
          const box = (r, dx, dy) => ({ x: Math.round(r.left + dx), y: Math.round(r.top + dy), w: Math.round(r.width), h: Math.round(r.height) });
          const blocky = (el) => { const d = style(el).display; return !d.startsWith('inline') && d !== 'contents'; };
          const fresh = new WeakSet();
          let lastText = null, lastControl = null, texts = 0, styled = 0;
          const recentNames = [];
          const scrollers = [];   // boxes that clip what's inside them: what's scrolled out of them isn't visible now
          // Which record (result card, row) each thing is in: the view shows each record as one line.
          const recs = performance.now() - t0 < 100 ? (recordSet() || []) : [];
          const recIndex = new Map(recs.map((r, i) => [r, i]));
          const recOf = (el) => { if (!recIndex.size) return undefined; for (let n = el, d = 0; n && d < 12; n = n.parentElement, d++) if (recIndex.has(n)) return recIndex.get(n); return undefined; };
          const textBudget = all_ ? 400 : 70;
          const ownText = (el) => { for (const n of el.childNodes) if (n.nodeType === 3 && n.textContent.trim()) return true; return false; };
          const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'HEAD', 'svg', 'SVG', 'PATH', 'OPTION']);
          // A grid is shown as a grid: its size, the selected cell, and every cell with something in it by its
          // address ("B1 "Voltage / V""), not as loose text. Its cells are clicked, typed or pasted into by address.
          const grids = new Map();
          for (const g of document.querySelectorAll('[role=grid],[role=treegrid]')) {
            if (!seen(g) || g.getBoundingClientRect().width < 120) continue;
            const cells = [...g.querySelectorAll('[role=gridcell],[role=cell]')];
            if (cells.length < 4) continue;
            const filled = [], addrs = [];
            let selected = '';
            for (const c of cells) {
              const a = cellAddress(c, g); if (!a) continue;
              addrs.push(a);
              if (c.getAttribute('aria-selected') === 'true' || c === document.activeElement) selected = a;
              const v = clean(c.innerText || c.textContent);
              if (v && filled.length < 120) filled.push(a + ' "' + v.slice(0, 40) + '"');
            }
            if (!addrs.length) continue;
            const rowsN = Math.max(...addrs.map((a) => +a.replace(/^[A-Z]+/, ''))), colsN = new Set(addrs.map((a) => a.replace(/\d+$/, ''))).size;
            const name = clean(g.getAttribute('aria-label') || '') || 'grid';
            grids.set(g, { context: 'grid', ref: refOf(g), text: `Grid "${name}" (${rowsN} rows × ${colsN} columns, cells by address like B2${selected ? '; selected ' + selected : ''}): `
              + (filled.length ? filled.join(' · ') : 'empty') + (filled.length >= 120 ? ' …' : '') });
          }
          const gridOf = (el) => { if (!grids.size) return null; const g = el.closest && el.closest('[role=grid],[role=treegrid]'); return g && grids.has(g) ? g : null; };
          const realControl = 'a[href],button,input,select,textarea,[role=button],[role=link],[role=checkbox],[role=combobox],[role=menuitem]';
          const items = all((el, dx, dy, out) => {
            if (out.length >= 700) return false;
            if (skip.has(el.tagName)) return;
            if (grids.size) {
              if (grids.has(el)) { out.push(grids.get(el)); return; }
              const g = gridOf(el);
              if (g && !el.matches(realControl)) return;   // its cells and their text are in the grid's line
            }
            const said = context(el);
            if (said) {
              const text = clean(el.innerText || el.textContent).slice(0, 200);
              const r = el.getBoundingClientRect();
              if (text && seen(el) && near(r.top + dy, r.height, 1200)) {
                const hr = recOf(el);
                out.push({ context: said, text, level: said === 'heading' ? Number((el.tagName.match(/\d/) || [el.getAttribute('aria-level') || 2])[0]) : 0, box: box(r, dx, dy), ...(hr !== undefined ? { rec: hr } : {}) });
                lastText = el;
              }
              if (said === 'alert') return;
            }
            let control = matches(el);
            const r = el.getBoundingClientRect();
            const inView = near(r.top + dy, r.height, 1200);
            // Clickable by script only: the pointer cursor starts here (not inherited), nothing inside or around is a control.
            if (!control && inView && r.width >= 8 && r.height >= 8 && performance.now() - t0 < 250 && r.width * r.height < W * H * 0.5) {
              styled++;
              const st = style(el);
              // A pointer, or a hand to grab or move it (a card on a board, a row in a sortable list): something to act on.
              const acts = /^(pointer|grab|-webkit-grab|move)$/.test(st.cursor);
              if (acts && el.parentElement && style(el.parentElement).cursor !== st.cursor
                  && !el.closest(interactive) && !el.querySelector(interactive) && seen(el)) {
                clickables.add(el); fresh.add(el); control = true;
              }
              // A box that scrolls on its own (a results list beside a map, a chat): say how much more there is.
              if (/(auto|scroll|hidden)/.test(st.overflowY + st.overflowX) && el.clientHeight > 80 && el !== document.scrollingElement
                  && (el.scrollHeight > el.clientHeight + 4 || el.scrollWidth > el.clientWidth + 4)) scrollers.push(el);
              if (/(auto|scroll)/.test(st.overflowY + st.overflowX) && el.clientHeight > 80 && el !== document.scrollingElement) {
                const down = el.scrollHeight - el.clientHeight - el.scrollTop, right = el.scrollWidth - el.clientWidth - el.scrollLeft;
                if (down > 40 || el.scrollTop > 40 || right > 80) {
                  const label = el.getAttribute('aria-label') || (el.querySelector('h1,h2,h3,[role=heading]') || {}).innerText || '';
                  out.push({ context: 'scroll', ref: refOf(el), name: clean(label).slice(0, 60), below: Math.round(down), above: Math.round(el.scrollTop),
                             right: right > 80 ? Math.round(right) : 0, box: box(r, dx, dy) });
                }
              }
            }
            // What draws itself: words in it aren't elements, so it's acted on by point (or its ref, at its middle).
            if (!control && ['CANVAS', 'VIDEO', 'EMBED', 'OBJECT'].includes(el.tagName) && r.width >= 80 && r.height >= 60 && inView && seen(el)) {
              const label = el.getAttribute('aria-label') || el.getAttribute('title') || (el.closest('[aria-label]') || {}).getAttribute?.('aria-label') || '';
              out.push({ context: 'media', ref: refOf(el), kind: el.tagName.toLowerCase(), name: clean(label).slice(0, 60), box: box(r, dx, dy) });
              return;
            }
            if (control) {
              const f = face(el); if (!f) return;
              const fr = f.getBoundingClientRect();
              if (!near(fr.top + dy, fr.height, 1200)) return;
              const item = describe(el, f, dx, dy);
              // Scrolled out of a box it's in (the months of a calendar after the first two, a carousel's far cards).
              for (const box of scrollers) {
                if (!contains(box, el)) continue;
                const b = box.getBoundingClientRect();
                if (fr.bottom <= b.top + 2 || fr.top >= b.bottom - 2 || fr.right <= b.left + 2 || fr.left >= b.right - 2) { item.clipped = refOf(box); break; }
              }
              // On screen but under something else (a dialog, a banner): a click wouldn't reach it.
              if (fr.top >= 0 && fr.bottom <= f.ownerDocument.defaultView.innerHeight && fr.left >= 0 && fr.right <= f.ownerDocument.defaultView.innerWidth) {
                const hit = hitAt(f.ownerDocument, fr.left + fr.width / 2, fr.top + fr.height / 2);
                if (hit && !reaches(el, f, hit) && !ownSkin(el, hit)) {
                  const hr = (hit.getBoundingClientRect && hit.getBoundingClientRect()) || { width: 0, height: 0 };
                  if (!(hr.width * hr.height < fr.width * fr.height * 0.3)) item.covered = true;   // a small badge on it isn't cover
                }
              }
              const ri = recOf(el); if (ri !== undefined) item.rec = ri;
              out.push(item);
              lastControl = el;
              recentNames.push(String(item.name || '').toLowerCase(), String(item.value || '').toLowerCase());
              if (recentNames.length > 8) recentNames.splice(0, recentNames.length - 8);
              return;
            }
            // The words: a block's text once (not again for what's inside it), not a control's own name again.
            if (texts >= textBudget || !ownText(el) || (lastText && contains(lastText, el)) || (lastControl && contains(lastControl, el)) || el.closest(interactive)) return;
            let block = el;
            while (block.parentElement && !blocky(block) && block.parentElement !== document.body) block = block.parentElement;
            if (lastText && contains(lastText, block)) return;
            const br = block.getBoundingClientRect();
            if (!near(br.top + dy, br.height, all_ ? 1e9 : 700) || !seen(block)) return;
            const text = clean(block.innerText);
            if (text.length < 2) return;
            // Words that are mostly the links and buttons inside them (a menu, a directory row): the controls say it.
            let linked = 0;
            for (const a of block.querySelectorAll('a, button, [role=link], [role=button]')) linked += clean(a.innerText).length;
            if (linked > text.length * 0.5) { lastText = block; return; }
            // Not the words of a control just listed again (a tooltip, a label beside it).
            const bare = text.replace(/[\u200b-\u200f\u2060\ufeff]/g, '').toLowerCase();
            if (recentNames.some((n) => n && (n === bare || (bare.length < 40 && n.includes(bare))))) return;
            lastText = block; texts++;
            const tr = recOf(block);
            out.push({ context: 'text', text: text.length > 180 ? text.slice(0, 177) + '…' : text, box: box(br, dx, dy), ...(tr !== undefined ? { rec: tr } : {}) });
          });
          // Names shared by several controls, or too short to say anything: where each one is.
          const counts = new Map();
          for (const it of items) if (it.ref && !it.context) counts.set(it.role + '|' + it.name, (counts.get(it.role + '|' + it.name) || 0) + 1);
          let placed = 0; const tw = performance.now();
          for (const it of items) {
            if (!it.ref || it.context || placed > 150 || performance.now() - tw > 250) continue;
            if (counts.get(it.role + '|' + it.name) > 1 || (it.name && it.name.length <= 3)) {
              const el = find(it.ref); const w = el ? within(el, it.name) : '';
              if (w) { it.within = w; placed++; }
            }
          }
          // The addresses the page's own search and filter forms build: a route that skips the typing.
          let forms = 0;
          for (const form of document.querySelectorAll('form')) {
            if (forms >= 3 || (form.method || 'get').toLowerCase() !== 'get' || !seen(form)) continue;
            const fields = [...form.elements].filter((e) => e.name && !e.disabled && !['submit', 'button', 'image', 'file', 'password', 'reset'].includes(e.type));
            if (!fields.some((e) => typable(e) && seen(e))) continue;
            let action; try { action = new URL(form.getAttribute('action') || location.href, location.href); } catch (_) { continue; }
            if (!/^https?:$/.test(action.protocol)) continue;
            const params = [];
            for (const e of fields) {
              if (e.type === 'hidden') { if (e.value && e.value.length <= 40) params.push(e.name + '=' + encodeURIComponent(e.value)); continue; }
              if ((e.type === 'checkbox' || e.type === 'radio') && !e.checked) continue;
              if (e.tagName === 'SELECT') { params.push(e.name + '={' + [...e.options].slice(0, 4).map((o) => o.value).join('|') + (e.options.length > 4 ? '|…' : '') + '}'); continue; }
              if (typable(e)) { params.push(e.name + '={' + (clean(name(e)) || e.name).slice(0, 30) + '}'); continue; }
              if (e.value && e.value.length <= 40) params.push(e.name + '=' + encodeURIComponent(e.value));
            }
            if (!params.length) continue;
            forms++;
            items.push({ context: 'form', text: (action.origin + action.pathname + '?' + params.join('&')).slice(0, 300) });
          }
          let pageKind = '';
          // What kind of page this is and where its parts are, as an experienced person sees at a glance:
          // results with a search box, filter groups and a sort; an item with its buy button; a sign-in;
          // a checkout; a form; an article. The agent starts from the map instead of reading every control.
          {
            let searchEl = null, buy = null, pw = null, card = null, sortEl = null, fields = 0;
            const groups = new Map();
            const shownIn = new Set();
            const option = (el) => {
              const w = within(el);
              if (!w || w.length > 40 || /^\d{4}-\d{2}-\d{2}/.test(w) || /consent|cookie|privacy|legitimate interest|leg\.? ?interest|vendors?|partners?/i.test(w)) return;
              groups.set(w, (groups.get(w) || 0) + 1);
              const face = el.labels && el.labels[0] || el;
              if (seen(face) || seen(el)) shownIn.add(w);
            };
            walk(document.body || document.documentElement, 0, 0, (el) => {
              if (/^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT|SVG)$/i.test(el.tagName)) return;
              const tag = el.tagName, r = el.getAttribute('role');
              if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
                if (el.type === 'hidden' || el.disabled) return;
                const said = [el.name, el.id, el.getAttribute('autocomplete'), el.getAttribute('placeholder'), el.getAttribute('aria-label')].join(' ');
                if (el.type === 'checkbox' || el.type === 'radio') { option(el); return; }
                if (!seen(el)) return;
                if (el.type === 'password') { pw = pw || el; return; }
                if (/cc-number|card.?num|cardnumber|credit.?card/i.test(said)) { card = card || el; return; }
                if (!searchEl && (el.type === 'search' || r === 'searchbox' || /\b(search|query|keywords?)\b|^q$|\bq\b/i.test(said) || el.closest('form[role=search], [role=search]'))) { searchEl = el; return; }
                if (tag === 'SELECT' && /sort/i.test(name(el) + ' ' + said)) { sortEl = sortEl || el; return; }
                if (typable(el) || tag === 'SELECT') fields++;
                return;
              }
              if (r === 'checkbox' || r === 'radio' || r === 'switch' || r === 'menuitemcheckbox') { option(el); return; }
              if ((tag === 'BUTTON' || tag === 'A' || r === 'button' || r === 'link') && seen(el)) {
                const t = clean(name(el)).slice(0, 60);
                if (!buy && /^(add to (cart|bag|basket|trolley)|buy( it)? now|add to order|reserve|book( now)?|select (this )?(room|seat|flight|fare)|proceed to checkout|checkout|place (your )?order)\b/i.test(t)) buy = el;
                else if (!sortEl && /^sort( by)?\b/i.test(t)) sortEl = el;
              }
            });
            const filterGroups = [...groups].filter(([g, n]) => n >= 2 && shownIn.has(g));
            const textLen = (document.body && document.body.innerText || '').length;
            let kind = '';
            if (card) kind = 'checkout (payment details)';
            else if (pw) kind = fields >= 3 ? 'sign-up or account form' : 'sign-in';
            else {
              // Results answer a query: words in a search box, a query in the address, or a stated count.
              const asked = (searchEl && clean(searchEl.value)) || /[?&][^=&]+=[^&]/.test(location.search)
                || /(?<![\d:.,$£€])\b\d[\d,]*\+?\s+(results?|matches|items|products|listings|properties)\b/i.test((document.body && document.body.innerText || '').slice(0, 20000));
              // An article reads as long paragraphs; a grid or a front page as short blurbs.
              const longParas = [...document.querySelectorAll('p')].filter((x) => (x.innerText || '').length > 200
                && !x.closest('footer, nav, aside, header, [role=contentinfo], [role=dialog], [aria-modal=true], [role=navigation], [role=complementary]')).length;
              if (recs.length >= 3 && asked && (filterGroups.length || sortEl || searchEl)) kind = 'results';
              else if (buy && recs.length < 6) kind = 'item';
              else if (fields >= 3) kind = 'form (' + fields + ' fields)';
              else if (longParas >= 4) kind = 'article';
              else if (recs.length >= 3) kind = asked ? 'results' : 'list';
            }
            pageKind = kind;
            const at = (el) => '[' + refOf(el) + ']';
            const mapParts = [];
            if (kind) mapParts.push(kind);
            if (searchEl) mapParts.push('search ' + at(searchEl) + (clean(searchEl.value) ? ' = "' + clean(searchEl.value).slice(0, 40) + '"' : ''));
            if (filterGroups.length && kind !== 'article') mapParts.push('filters: ' + filterGroups.slice(0, 8).map(([g, n]) => g + ' (' + n + ')').join(', ') + (filterGroups.length > 8 ? ' +' + (filterGroups.length - 8) + ' more groups' : ''));
            if (sortEl) mapParts.push('sort ' + at(sortEl));
            if (buy) mapParts.push(clean(name(buy)).slice(0, 30) + ' ' + at(buy));
            if (pw) mapParts.push('password ' + at(pw));
            if (card) mapParts.push('card number ' + at(card));
            if (mapParts.length && (kind || mapParts.length >= 2)) items.push({ context: 'map', text: mapParts.join(' · ').slice(0, 500) });
          }
          // What the page is set to now, read from the page itself: what's ticked or switched on
          // (in collapsed sections too), the tab and buttons pressed, each dropdown's choice, a sort,
          // applied-filter chips, what's typed in its fields, how many results and which of them
          // are shown, and the address's own settings. One line: the agent never has to guess
          // whether a filter or sort it set actually took.
          {
            const on = [], tabs = [], pressed = [], picks = [], chips = [], typed = [], current = [];
            const seenNames = new Set();
            const add = (list, cap, t) => { t = clean(t); if (t && list.length < cap && !seenNames.has(t)) { seenNames.add(t); list.push(t); } };
            const grouped = (el, n) => { const w = within(el); return w && !n.includes(w) && w.length <= 40 ? n + ' (' + w + ')' : n; };
            walk(document.documentElement, 0, 0, (el) => {
              if (/^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT|SVG)$/i.test(el.tagName)) return;
              const r = el.getAttribute('role');
              const n = () => clean(name(el)).slice(0, 60);
              if (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio')) {
                if (el.checked && !el.disabled) { const t = n(); if (t) add(on, 14, grouped(el, t)); }
                return;
              }
              if ((r === 'checkbox' || r === 'switch' || r === 'menuitemcheckbox' || r === 'menuitemradio' || r === 'radio') && el.getAttribute('aria-checked') === 'true') { const t = n(); if (t) add(on, 14, grouped(el, t)); return; }
              if (r === 'tab' && el.getAttribute('aria-selected') === 'true' && seen(el)) { add(tabs, 4, n()); return; }
              if (el.getAttribute('aria-pressed') === 'true' && seen(el)) { add(pressed, 6, n()); return; }
              const cur = el.getAttribute('aria-current');
              if (cur && cur !== 'false' && seen(el) && el.closest('nav, [role=navigation], ol, ul')) { add(current, 2, n()); return; }
              if (el.tagName === 'SELECT' && seen(el)) {
                const o = el.selectedOptions && el.selectedOptions[0];
                const label = clean(name(el)) || el.name || '';
                if (o) add(picks, 6, (label && !label.includes(clean(o.text)) ? label.slice(0, 40) + ': ' : '') + clean(o.text).slice(0, 50));
                return;
              }
              if ((r === 'combobox' || el.tagName === 'BUTTON' || r === 'button') && seen(el)) {
                const t = n();
                if (/\bsort(ed)?( by)?\s*[:\-–]\s*\S|\bsort(ed)? by \S/i.test(t)) { add(picks, 6, t); return; }
                if (/^(remove|clear|delete)\b|[×✕✖]\s*$/i.test(t) && !/^(clear|remove|delete)( all)?( filters)?$/i.test(t)) {
                  const chip = t.replace(/^(remove|clear|delete)\s*(filter)?:?\s*/i, '').replace(/\s*[×✕✖]\s*$/, '');
                  if (!/^(the )?(search|text|input|query|field|all|filters?|selection|form)( box| field| text)?$/i.test(chip)) add(chips, 8, chip);
                  return;
                }
              }
              if (typable(el) && el.type !== 'password' && !vaulted.has(el) && seen(el) && (el.disabled || el.getAttribute('aria-disabled') === 'true')) {
                add(typed, 5, '“' + (clean(name(el)).slice(0, 30) || 'a field') + '” is off for now ({"wait": "input"} waits for it)'); return;
              }
              if (typable(el) && el.type !== 'password' && !vaulted.has(el) && seen(el)) {
                const v = clean(el.value);
                if (v && v.length <= 80) {
                  // The field's label up to its first pause ("Departure date . Enter a date" → "Departure date");
                  // none when the label already says the value (a field named by what's in it).
                  const label = clean(name(el));
                  const short = label.includes(v) ? '' : (label.split(/\s*[.;:,]\s+|\s+[.·]\s+/)[0] || el.name || '').slice(0, 30);
                  // A field with no name of its own, or named only by its value, says nothing (a slider's "0", "10").
                  if (short || (label && label !== v && v.length > 2 && !/^\d+$/.test(v))) add(typed, 5, (short ? short + ' = ' : '') + '"' + v + '"');
                }
              }
            });
            const body = (document.body && document.body.innerText || '').slice(0, 30000);
            const counts = [];
            const span = body.match(/(?<![\d:.,$£€])\b(\d[\d,]*)\s*[-–]\s*(\d[\d,]*)\s+of\s+(?:over\s+|about\s+)?(\d[\d,]*\+?)\b/i);
            if (span) counts.push(span[1] + '–' + span[2] + ' of ' + span[3]);
            const total = body.match(/(?<![\d:.,$£€])\b(\d[\d,]*\+?)\s+(results?|matches|search results)\b/i) || body.match(/(?<![\d:.,$£€])\b(\d[\d,]*\+?)\s+(results?|matches|items|listings|properties|stays|homes|products|jobs|courses|flights|hotels|rentals|places|options|vehicles|cars|events|articles|models|repositories|recipes)\b/i);
            if (total && !(span && span[3].replace(/\D/g, '') === total[1].replace(/\D/g, ''))) counts.push(total[1] + ' ' + total[2]);
            const total0 = total;
            const pages = body.match(/\bpage\s+(\d+)\s+of\s+(\d+)\b/i);
            if (pages) counts.push('page ' + pages[1] + ' of ' + pages[2]);
            let address = '';
            try {
              const q = new URLSearchParams(location.search);
              const kept = [];
              // Settings, not trackers: no utm/session keys, and no values that look like random tokens.
              const token = (v) => (v.length >= 14 && /^[\w-]+$/.test(v) && /\d/.test(v) && /[a-z]/.test(v) && /[A-Z]/.test(v)) || /^\d{10,}$/.test(v);
              for (const [k, v] of q) if (v && v.length <= 60 && !token(v) && !/^(utm_|ref|_|session|token|sid|gclid|fbclid)/i.test(k) && kept.length < 10) kept.push(k + '=' + v);
              address = kept.join('&');
            } catch (_) {}
            const parts = [];
            if (on.length) parts.push('on: ' + on.join(', '));
            if (tabs.length) parts.push('tab: ' + tabs.join(', '));
            if (pressed.length) parts.push('pressed: ' + pressed.join(', '));
            if (picks.length) parts.push(picks.join(' · '));
            if (chips.length) parts.push('applied: ' + chips.join(', '));
            if (current.length) parts.push('current: ' + current.join(', '));
            if (typed.length) parts.push(typed.join(' · '));
            if (counts.length) parts.push(counts.join(', '));
            if (address) parts.push('address ?' + address);
            if (parts.length) items.push({ context: 'state', text: parts.join(' · ').slice(0, 700) });

            // How far through: how many alike items (results, rows, cards) the page holds, which are in
            // view, the total it claims, and the way to the rest (next, load more, numbered pages) or
            // that there is none. The agent never stops at 100 of 1,000 believing it has them all.
            const listParts = [];
            const n = recs.length >= 3 ? recs.length : 0;
            let listTotal = null;
            if (span) listTotal = span[3]; else if (total0) listTotal = total0[1];
            const sizes = recs.slice(0, 3).map((r) => r.getAttribute('aria-setsize') || (r.parentElement && (r.parentElement.getAttribute('aria-rowcount') || r.parentElement.getAttribute('aria-setsize')))).filter((v) => v && +v > 0);
            if (!listTotal && sizes.length) listTotal = sizes[0];
            if (n) {
              let first = -1, last = -1;
              recs.forEach((r, i) => { const b = r.getBoundingClientRect(); if (b.bottom > 0 && b.top < innerHeight && b.height > 0) { if (first < 0) first = i; last = i; } });
              listParts.push(n + ' alike items on the page' + (first >= 0 ? ' (items ' + (first + 1) + '–' + (last + 1) + ' in view)' : ''));
            }
            if (listTotal) listParts.push('the page says ' + listTotal + ' in all');
            let nextEl = null, nextOff = false, more = null, maxPage = 0;
            walk(document.body || document.documentElement, 0, 0, (el) => {
              if (/^(SCRIPT|STYLE|TEMPLATE|NOSCRIPT|SVG)$/i.test(el.tagName)) return;   // (false would end the whole walk)
              const tag = el.tagName, r = el.getAttribute('role');
              if (!(tag === 'A' || tag === 'BUTTON' || r === 'link' || r === 'button' || (tag === 'INPUT' && /^(button|submit)$/.test(el.type)))) return;
              const label = clean(el.getAttribute('aria-label') || el.getAttribute('title') || el.innerText || el.value || '');
              const off = el.disabled || el.getAttribute('aria-disabled') === 'true' || /\bdisabled\b/i.test(el.className || '');
              // A list's next page, not a calendar's next month or a carousel's next slide.
              const elsewhere = /\b(month|week|day|year|slide|image|photo|picture|video|story|stories|step|tab|question|chapter|article|post)s?\b/i.test(label);
              if (!nextEl && !elsewhere && (el.getAttribute('rel') === 'next' || /^(next|next page|go to next page|next results|more results|older posts|older|›|»|→|>|>>)$/i.test(label) || /^next\b.{0,20}$/i.test(label))) {
                if (off) nextOff = true; else if (seen(el) || el.getBoundingClientRect().height > 0) nextEl = el;
                return;
              }
              if (!more && !off && !elsewhere && !/filters?|options|categories|brands|amenities|facilities/i.test(label) && /^(load|show|see|view)\s+(\d+\s+)?more\b|^more\s+(results|items|reviews|products)$|^show all\b|^see all results\b/i.test(label) && label.length < 50) { more = el; return; }
              if (/^\d{1,4}$/.test(label) && el.closest('nav, [role=navigation], [class*=pagin], [class*=Pagin], [aria-label*=agination], [aria-label*=pages]')) maxPage = Math.max(maxPage, +label);
            });
            const said = (el) => '[' + refOf(el) + '] ' + (role(el) || 'button') + ' "' + clean(name(el)).slice(0, 40) + '"';
            if (nextEl) listParts.push('more on the next page: ' + said(nextEl));
            if (more) listParts.push('more here: ' + said(more));
            if (maxPage > 1) listParts.push('numbered pages up to ' + maxPage);
            if (nextOff && !nextEl) listParts.push('next is disabled: this is the last page');
            const se2 = document.scrollingElement || document.documentElement;
            const below = Math.round(se2.scrollHeight - se2.scrollTop - innerHeight);
            if (n && !nextEl && !more && !nextOff && maxPage <= 1) {
              listParts.push(below > 300 ? 'no next or load-more control; more may load as you scroll down (' + below + 'px below)'
                                         : 'no next or load-more control and the page ends here');
            }
            // Only for a list: alike items, or a total the page states. A calendar's "Next month" isn't a next page.
            if (listParts.length && (n || listTotal) && !/^(sign-in|sign-up|checkout|item|form)/.test(pageKind)) items.push({ context: 'list', text: listParts.join(' · ').slice(0, 400) });
          }
          const se = document.scrollingElement || document.documentElement;
          items.push({ context: 'page', below: Math.max(0, Math.round(se.scrollHeight - se.scrollTop - innerHeight)), above: Math.round(se.scrollTop),
                       truncated: texts >= textBudget, ms: Math.round(performance.now() - t0) });
          return items;
        },
        // The page's words as plain Markdown: headings, paragraphs, lists, table rows as
        // "a | b | c", through open shadow roots and same-origin frames, only what's shown.
        // main: just the main content (no navigation, header, footer, sidebars).
        markdown(main, max) {
          const out = []; let size = 0;
          const visible = (el) => el.checkVisibility ? el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) : seen(el);
          const isBlock = (el) => { const d = style(el).display; return d !== 'none' && !d.startsWith('inline') && d !== 'contents'; };
          const chrome = /^(navigation|banner|contentinfo|complementary|search)$/;
          const push = (line) => {
            line = line.replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n').trim();
            if (!line || size > max) return;
            if (out.length && out[out.length - 1] === line) return;
            out.push(line); size += line.length + 1;
          };
          const kidsOf = (el) => {
            if (el.shadowRoot) return [...el.shadowRoot.childNodes];
            if (el.tagName === 'SLOT') return el.assignedNodes({ flatten: true });
            if (el.tagName === 'IFRAME') { let d = null; try { d = el.contentDocument; } catch (_) {} return d && d.body ? [d.body] : []; }
            return [...el.childNodes];
          };
          const walkMd = (el, prefix) => {
            if (size > max || el.nodeType !== 1) return;
            const tag = el.tagName;
            if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'svg', 'SVG', 'HEAD', 'SELECT', 'OPTION'].includes(tag)) return;
            if (!visible(el) && tag !== 'SLOT') return;
            const r = el.getAttribute('role') || '';
            if (main && (['NAV', 'FOOTER', 'ASIDE', 'HEADER'].includes(tag) && !el.closest('main,article,[role=main]') || chrome.test(r))) return;
            // Main content only: a block that's all links and buttons (tabs, menus, toolbars) is furniture.
            if (main && el.childElementCount >= 3) {
              const all = clean(el.innerText);
              if (all.length && all.length < 600) {
                let linked = 0;
                el.querySelectorAll('a, button, label, [role=button], [role=tab], [role=menuitem], [role=link]').forEach((a) => { if (!a.parentElement.closest('a, button, label, [role=button], [role=tab], [role=menuitem], [role=link]') || a.parentElement === el) linked += clean(a.innerText).length; });
                if (linked / all.length > 0.8) return;
              }
            }
            if (/^H[1-6]$/.test(tag) || r === 'heading') {
              if (!clean(el.innerText)) return;
              push('#'.repeat(Number((tag.match(/\d/) || [el.getAttribute('aria-level') || 2])[0])) + ' ' + clean(el.innerText)); return;
            }
            if (tag === 'TR' || r === 'row') {
              const cells = [...el.children].filter(visible).map((c) => clean(c.innerText)).filter(Boolean);
              if (cells.length) push(prefix + cells.join(' | ')); return;
            }
            if (tag === 'IMG') { const alt = clean(el.getAttribute('alt')); if (alt && alt.length > 3) push(prefix + '[image: ' + alt.slice(0, 100) + ']'); return; }
            if (tag === 'INPUT' || tag === 'TEXTAREA') return;
            const kids = kidsOf(el);
            const deep = el.shadowRoot || tag === 'IFRAME' || tag === 'SLOT' ||
              kids.some((k) => k.nodeType === 1 && (k.shadowRoot || k.tagName === 'IFRAME' || k.tagName === 'SLOT' || (visible(k) && isBlock(k))));
            const mark = tag === 'LI' ? '- ' : tag === 'BLOCKQUOTE' ? '> ' : '';
            if (!deep) { const t = clean(el.innerText); if (t) push(prefix + mark + t); return; }
            let run = '';
            for (const k of kids) {
              if (k.nodeType === 3) { run += k.textContent; continue; }
              if (k.nodeType !== 1) continue;
              if (!isBlock(k) && !k.shadowRoot && k.tagName !== 'IFRAME' && k.tagName !== 'SLOT') { if (visible(k)) run += ' ' + (k.innerText || '') + ' '; continue; }
              if (clean(run)) { push(prefix + mark + clean(run)); run = ''; }
              walkMd(k, prefix + (mark === '- ' ? '  ' : ''));
            }
            if (clean(run)) push(prefix + mark + clean(run));
          };
          let root = document.body;
          if (main) {
            const cands = [...document.querySelectorAll('main,[role=main],article')].filter(visible);
            if (cands.length) root = cands.sort((a, b) => b.innerText.length - a.innerText.length)[0];
          }
          if (root) walkMd(root, '');
          const text = out.join('\n');
          return { text: text.slice(0, max), truncated: size > max, main: !!main && root !== document.body };
        },
        // Custom elements whose insides are hidden (closed shadow roots): Sill asks Chromium's accessibility tree.
        opaque() {
          const out = [];
          walk(document.documentElement, 0, 0, (el) => {
            if (el.tagName.includes('-') && !el.shadowRoot && !el.children.length && seen(el) && out.length < 30) {
              const token = 'o' + (next++); el.setAttribute('data-sill-pick', token); out.push(token);
            }
          });
          return out;
        },
        // Finds it, scrolls it into view, waits until it stops moving (a smooth
        // scroll, an animation), and checks a click there would reach it.
        async locate(ref, selector, text, editable, scope) {
          this.watch();   // from before the action, so its first change is seen
          lastScope = scope || null;
          const first = this.place(ref, selector, text, false, editable);
          if (!first || first.gone || first.ambiguous) return first;
          const el = find(first.ref); if (!el) return first;
          const f = face(el) || el;
          let last = f.getBoundingClientRect(), still = 0;
          for (let i = 0; i < 20 && still < 2; i++) {
            await frame();
            const now = f.getBoundingClientRect();
            still = Math.abs(now.left - last.left) < 0.5 && Math.abs(now.top - last.top) < 0.5 ? still + 1 : 0;
            last = now;
          }
          let placed = this.place(first.ref, null, null, true);
          // Under something (a sticky header, a banner) at the edge: try it in the middle.
          if (placed && placed.coveredBy && !placed.gone) {
            f.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
            await frame(); await frame();
            if (find(first.ref)) placed = this.place(first.ref, null, null, true);
          }
          // Still covered: often a menu mid-animation (it takes clicks only once open). Up to ~0.6 s.
          for (let i = 0; i < 36 && placed && placed.coveredBy && find(first.ref); i++) {
            await frame();
            placed = this.place(first.ref, null, null, true);
          }
          return placed;
        },
        // Where a click on it lands, for checking afterwards that it did.
        // Before typing: a combobox or popup trigger not yet open gets a real click first
        // (that's what opens its field). After: if the page moved the focus to a field of its
        // own (the search box of a popup that opened), that's where the typing goes.
        prepType(ref) {
          const el = find(ref); if (!el) return { click: false };
          const active = deepActive();
          const opener = el.getAttribute('role') === 'combobox' || el.hasAttribute('aria-haspopup') || el.getAttribute('aria-expanded') === 'false';
          return { click: opener && active !== el && !contains(el, active) };
        },
        retarget(ref) {
          const el = find(ref); const active = deepActive();
          if (!el || !active || active === el || contains(el, active) || !typable(active) || !seen(active)) return null;
          const opener = el.getAttribute('role') === 'combobox' || el.hasAttribute('aria-haspopup') || el.hasAttribute('aria-expanded') || lastClicked === el || !typable(el);
          return opener ? { ref: refOf(active), name: name(active) } : null;
        },
        arm(ref, button) {
          window.__sillAgentClickAt = performance.now();
          const el = find(ref); if (!el) return false;
          lastClicked = el;
          const doc = el.ownerDocument, win = doc.defaultView;
          window.__sillLanding = null;
          window.__sillPressed = false;
          const reached = (e) => e.composedPath().includes(el) || (el.labels && [...el.labels].some((l) => e.composedPath().includes(l)));
          // The press reaching it counts: many lists choose on press and close, so the click that follows
          // lands on what was underneath (or nowhere) though the choice was made.
          win.addEventListener('pointerdown', (e) => { if (reached(e)) window.__sillPressed = true; }, { capture: true, once: true });
          // A right button makes contextmenu, a middle one auxclick: no click.
          win.addEventListener(button === 'right' ? 'contextmenu' : button === 'middle' ? 'auxclick' : 'click', (e) => {
            window.__sillLanding = { hit: reached(e) || window.__sillPressed,
                                     on: name(e.composedPath()[0] instanceof Element ? e.composedPath()[0] : el).slice(0, 60) };
          }, { capture: true, once: true });
          return true;
        },
        landed() { return window.__sillLanding || (window.__sillPressed ? { hit: true, on: 'pressed' } : null); },
        place(ref, selector, text, settled, editable) {
          let el = ref ? find(ref) : null;
          // Re-rendered since the last look: the one control with the same role and name is the same
          // control (never a lookalike: two or more with that name, and the old ref is refused).
          if (ref && !el && metas.has(ref)) {
            const m = metas.get(ref), same = [];
            walk(document.documentElement, 0, 0, (e, dx, dy) => {
              offsets.set(e, [dx, dy]);
              if (matches(e) && role(e) === m.role && name(e) === m.name && face(e)) { same.push(e); if (same.length > 1) return false; }
            });
            if (same.length === 1) el = same[0];
          }
          if (ref && !el) return { gone: known(ref) || /^e\d+$/.test(ref) };
          if (!el && selector) el = deepQuery(selector);
          lastAmbiguous = null; lastScore = 0;
          const byName = !el && !!text && !(selector && deepQuery(selector));
          if (!el && text) el = byText(text, editable);
          if (!el && lastAmbiguous) return { ambiguous: lastAmbiguous };
          if (!el) return null;
          const f = face(el) || el;
          // Scrolled only if it isn't wholly in view, and only as far as needed:
          // a needless scroll makes some lists (virtual ones) re-render under the click.
          if (!settled) {
            const r0 = f.getBoundingClientRect(), win = f.ownerDocument.defaultView;
            const inside = r0.top >= 0 && r0.left >= 0 && r0.bottom <= win.innerHeight && r0.right <= win.innerWidth;
            let clipped = false;
            for (let p = f.parentElement; p && !clipped; p = p.parentElement) {
              const st = style(p);
              if (/(auto|scroll|hidden)/.test(st.overflow + st.overflowX + st.overflowY)) {
                const pr = p.getBoundingClientRect();
                clipped = r0.top < pr.top || r0.bottom > pr.bottom || r0.left < pr.left || r0.right > pr.right;
              }
            }
            // To the middle of the view, not its edge: a sticky top bar or bottom banner covers the edges.
            if (!inside || clipped) f.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
          }
          const off = offsets.get(el) || [0, 0];
          const r = f.getBoundingClientRect();
          const out = { ref: refOf(el), name: name(el), role: role(el), x: r.left + r.width / 2 + off[0], y: r.top + r.height / 2 + off[1],
                        w: r.width, h: r.height, disabled: !!(el.disabled || el.getAttribute('aria-disabled') === 'true'), visible: !!face(el),
                        partial: byName && lastScore < 3 && lastScore > 0 };
          // Covered? Try the middle, then a few points inside, before saying so.
          const doc = f.ownerDocument;
          const points = [[0.5, 0.5], [0.25, 0.5], [0.75, 0.5], [0.5, 0.25], [0.5, 0.75]];
          let ok = null, cover = null;
          for (const [px, py] of points) {
            const x = r.left + r.width * px, y = r.top + r.height * py;
            const hit = hitAt(doc, x, y);
            if (reaches(el, f, hit) || ownSkin(el, hit)) { ok = [x + off[0], y + off[1]]; break; }
            if (!cover) cover = hit;
          }
          if (ok) { out.x = ok[0]; out.y = ok[1]; }
          else if (cover) {
            // What's on top, said usefully: an open dialog (with its way out), a page-wide
            // overlay, or the control in the way.
            const up = (n) => n && (n.parentElement || (n.getRootNode() && n.getRootNode().host));
            let dialog = null;
            for (let n = cover; n && !dialog; n = up(n)) if (n.matches && n.matches('[role=dialog],[role=alertdialog],[aria-modal=true],dialog[open]')) dialog = n;
            if (dialog) {
              const exits = [...dialog.querySelectorAll('button,[role=button]')].filter((b) => /^(done|close|ok|apply|cancel|×|✕|x|dismiss|got it|accept( all)?)$/i.test(name(b)) && seen(b)).slice(0, 3);
              out.coveredBy = { dialog: name(dialog).slice(0, 50) || 'a dialog', ref: refOf(dialog), exits: exits.map((b) => ({ ref: refOf(b), name: name(b) })) };
            } else {
              const cr = cover.getBoundingClientRect();
              if (cr.width * cr.height > innerWidth * innerHeight * 0.6) out.coveredBy = { overlay: true, tag: cover.tagName.toLowerCase(), name: clean(cover.innerText).slice(0, 80) };
              else { let c = cover; while (c && !matches(c) && c.parentElement) c = c.parentElement;
                     out.coveredBy = { ref: c && matches(c) ? refOf(c) : null, name: name(c || cover).slice(0, 60), tag: (c || cover).tagName.toLowerCase() }; }
            }
          }
          return out;
        },
        click(ref) { const el = find(ref); if (!el) return false; el.focus && el.focus(); el.click(); return true; },
        focus(ref, clear) {
          const el = find(ref); if (!el) return false;
          el.focus();
          if (el.isContentEditable) {
            const range = document.createRange(); range.selectNodeContents(el);
            if (!clear) range.collapse(false);
            const selection = el.ownerDocument.getSelection(); selection.removeAllRanges(); selection.addRange(range);
          } else if (clear && el.select) {
            el.select();
          } else if (!clear && typeof el.value === 'string') {
            try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
          }
          const active = el.getRootNode().activeElement || el.ownerDocument.activeElement;
          return active === el || el.contains(active);
        },
        // Inputs that take a value, not keystrokes: dates, times, colours, ranges.
        setValue(ref, value) {
          const el = find(ref); if (!el || !('value' in el)) return false;
          set(el, value); return String(el.value) === String(value);
        },
        valueKind(ref) { const el = find(ref); return el && el.tagName === 'INPUT' ? el.type : (el && el.isContentEditable ? 'editable' : el ? el.tagName.toLowerCase() : null); },
        type(ref, text, clear) {
          const el = find(ref); if (!el || !typable(el)) return false;
          el.focus();
          if (el.isContentEditable) {
            if (clear) { document.execCommand('selectAll'); document.execCommand('delete'); }
            document.execCommand('insertText', false, text);
            return true;
          }
          set(el, (clear ? '' : el.value) + text);
          return true;
        },
        typed(ref) { const el = find(ref); return el ? (el.isContentEditable ? el.innerText : String(el.value)) : null; },
        choose(ref, value) {
          const el = find(ref); if (!el || el.tagName !== 'SELECT') return false;
          const want = String(value).toLowerCase();
          const all = [...el.options];
          // The same amount written another way ("$100" for "$100.00", "1,000" for "1000").
          const amount = (t) => { const m = String(t).replace(/[,\s]/g, '').match(/^[^\d-]*(-?\d+(?:\.\d+)?)[^\d]*$/); return m ? Number(m[1]) : null; };
          const one = (list) => list.length === 1 ? list[0] : null;
          const option = all.find((o) => o.value === value || o.text.trim() === value)
            || all.find((o) => o.text.trim().toLowerCase() === want || o.value.toLowerCase() === want)
            || (amount(value) !== null ? one(all.filter((o) => amount(o.text.trim()) === amount(value))) : null)
            || one(all.filter((o) => o.text.trim().toLowerCase().startsWith(want)))
            || one(all.filter((o) => o.text.trim().toLowerCase().includes(want)));
          if (!option) return false;
          set(el, option.value);
          return true;
        },
        options(ref) { const el = find(ref); return el && el.options ? [...el.options].map((o) => o.text.trim()) : []; },
        isSelect(ref) { const el = find(ref); return !!(el && el.tagName === 'SELECT'); },
        // A list a custom dropdown opened: the option named `value`, in the list it controls, else any shown option.
        optionRef(ref, value) {
          const el = find(ref); const want = clean(value).toLowerCase();
          const root = el ? el.getRootNode() : document;
          const lists = ((el && (el.getAttribute('aria-controls') || el.getAttribute('aria-owns'))) || '').split(/\s+/).filter(Boolean)
            .map((id) => (root.getElementById ? root.getElementById(id) : null) || document.getElementById(id)).filter(Boolean);
          const pool = (scope) => [...scope.querySelectorAll('[role=option],[role=menuitem],[role=menuitemradio],option,li')].filter(seen);
          let options = lists.flatMap(pool);
          if (!options.length) options = pool(document).filter((o) => o.matches('[role=option],[role=menuitem],[role=menuitemradio]') || o.closest('[role=listbox],[role=menu]'));
          const name = (o) => clean(o.getAttribute('aria-label') || o.innerText || o.textContent).toLowerCase();
          const hit = options.find((o) => name(o) === want) || options.find((o) => name(o).startsWith(want)) || options.find((o) => name(o).includes(want));
          return hit ? refOf(hit) : null;
        },
        draggable(ref) { const el = find(ref); return !!(el && el.closest && el.closest('[draggable=true]')); },
        // Changes that answer an action: elements coming or going, text, a widget's
        // state. Not style or class (animations churn them all the time), nor
        // anything inside svg or canvas. The watcher starts on first use, only in
        // pages an agent drives.
        watch() {
          if (window.__sillWatch) return;
          window.__sillLastChange = -1e9;
          window.__sillLastShape = -1e9;   // the page's structure: elements in or out, things opening or closing
          const inArt = (n) => { const el = n.nodeType === 1 ? n : n.parentElement; return !!(el && el.closest('svg, canvas, script, style, noscript, template')); };
          const counts = (n) => n.nodeType === 1 ? !/^(SCRIPT|STYLE|LINK|META|NOSCRIPT)$/.test(n.tagName) : n.nodeType === 3 && n.data.trim() !== '';
          window.__sillWatch = new MutationObserver((records) => {
            let changed = false;
            for (const r of records) {
              if (inArt(r.target)) continue;
              if (r.type === 'childList' && ![...r.addedNodes].some(counts) && ![...r.removedNodes].some(counts)) continue;
              changed = true;
              // A number ticking in place (a countdown, a clock, a live price) is text changing, not the page's shape.
              const shape = r.type === 'attributes' || (r.type === 'childList' && [...r.addedNodes, ...r.removedNodes].some((n) => n.nodeType === 1 && counts(n)));
              if (shape) { window.__sillLastShape = performance.now(); break; }
            }
            if (changed) window.__sillLastChange = performance.now();
          });
          window.__sillWatch.observe(document, { subtree: true, childList: true, characterData: true, attributes: true,
            attributeFilter: ['aria-expanded', 'aria-hidden', 'aria-selected', 'aria-checked', 'aria-pressed', 'aria-busy',
                              'aria-invalid', 'aria-disabled', 'hidden', 'open', 'disabled', 'value', 'checked', 'href', 'src'] });
        },
        // How the page is doing: its load state, and ms since it last changed (huge if it hasn't).
        state() {
          this.watch();
          return { ready: document.readyState, idle: performance.now() - window.__sillLastChange, still: performance.now() - window.__sillLastShape,
                   sinceAct: performance.now() - (window.__sillAgentClickAt || -1e9) };
        },
        quiet(ms) { return this.state().idle >= ms; },
        sending() {
          const el = document.activeElement;
          if (!el || el === document.body) return '';
          const form = el.form || el.closest('form');
          const button = form && form.querySelector('button[type=submit], input[type=submit], button:not([type])');
          return [name(el), button ? name(button) || button.value || '' : ''].filter(Boolean).join(' → ');
        },
        // What's in the way, cleared before the page is read: a cookie or consent banner turned
        // down the privacy-keeping way (reject, necessary only, or closed; never accepted), and a
        // newsletter, discount, app or notifications pop-up closed. Never a dialog with a password
        // field (a sign-in), never one with fields beyond an email. Says what it closed.
        clearWay(whole) {
          const out = [];
          // Something the agent itself just opened (Subscribe, Cookie settings) is its to use: left alone.
          if (window.__sillAgentClickAt && performance.now() - window.__sillAgentClickAt < 5000) return out;
          const H = innerHeight, W = innerWidth;
          const boxes = new Set();
          const up = (n) => n && (n.parentElement || (n.getRootNode() && n.getRootNode().host));
          const contain = (el) => {
            for (let n = el, d = 0; n && n !== document.body && n !== document.documentElement && d < 25; n = up(n), d++) {
              if (n.nodeType !== 1) continue;
              const r = n.getAttribute('role');
              if ((n.tagName === 'DIALOG' && n.open) || r === 'dialog' || r === 'alertdialog' || n.getAttribute('aria-modal') === 'true') return n;
              const p = style(n).position;
              if (p === 'fixed' || p === 'sticky') return n;
            }
            return null;
          };
          for (const [fx, fy] of [[0.5, 0.5], [0.5, 0.92], [0.5, 0.08], [0.15, 0.85], [0.85, 0.85], [0.5, 0.7], [0.5, 0.3]]) {
            for (const hit of document.elementsFromPoint(W * fx, H * fy).slice(0, 6)) { const c = contain(hit); if (c) boxes.add(c); }
          }
          // In a frame that is itself the banner (a consent service's own frame), the whole document is the box.
          if (whole && document.body) boxes.add(document.body);
          for (const el of document.querySelectorAll('dialog[open], [role=dialog], [role=alertdialog], [aria-modal=true], [id*=cookie i], [class*=cookie i], [id*=consent i], [class*=consent i]')) {
            if (el.tagName === 'BODY' || el.tagName === 'HTML') continue;
            const c = contain(el) || el; boxes.add(c);
          }
          const buttons = (box) => [...box.querySelectorAll('button, a, [role=button], input[type=button], input[type=submit]')].filter((b) => seen(b));
          const label = (b) => clean(b.getAttribute('aria-label') || b.innerText || b.value || b.getAttribute('title') || '');
          const done = new Set();
          for (const box of boxes) {
            if (done.has(box) || !box.isConnected || !seen(box)) continue;
            if ([...done].some((d) => d.contains(box))) continue;
            if (box === document.body && !whole) continue;
            const b = box.getBoundingClientRect();
            if (b.width < 160 || b.height < 30) continue;
            if (box.querySelector('input[type=password]')) continue;
            const text = clean(box.innerText).toLowerCase().slice(0, 3000);
            if (!text) continue;
            const fields = [...box.querySelectorAll('input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button]), textarea, select')].filter(seen);
            const consent = /cookie|consent|gdpr|personal data|privacy (settings|preferences|choices)|your (privacy )?choices|we (and our partners )?use (cookies|technologies)|tracking technologies/.test(text) && fields.length === 0;
            const promo = /newsletter|subscribe|sign up for (our|email|emails)|\d+% off|discount code|coupon|get the app|download (the|our) app|open in (the )?app|(enable|allow|turn on) (push )?notifications|exclusive offer|join (our|the) (list|club|mailing)|your first order/.test(text)
                          && fields.every((f) => f.type === 'email' || /e-?mail/i.test(name(f) || f.name || ''));
            if (!consent && !promo) continue;
            const bs = buttons(box);
            const pick = (re) => bs.find((x) => re.test(label(x)) && label(x).length <= 60);
            let btn = null;
            if (consent) btn = pick(/^(reject|decline|deny|refuse|disagree)( all| cookies| all cookies| optional cookies| non-essential( cookies)?)?$/i)
                            || pick(/^(only |use )?(strictly )?(necessary|essential|required)( cookies)?( only)?$/i)
                            || pick(/^(continue|proceed) without (accepting|agreeing)/i)
                            || pick(/^(reject|decline|refuse)\b/i);
            if (!btn) btn = pick(/^(close|dismiss|×|✕|✖|x|no,? thanks|no thank you|not now|maybe later|skip|continue to (the )?(site|website)|stay on (the )?(site|web))$/i)
                            || bs.find((x) => /^(close|dismiss)\b/i.test(x.getAttribute('aria-label') || x.getAttribute('title') || ''));
            if (!btn) { if (consent) out.push('a cookie banner is up and offers no way to turn it down: left it (Accept is the user\'s to choose)'); continue; }
            btn.click();
            done.add(box);
            out.push((consent ? 'a cookie banner, turned down' : 'a pop-up') + ' ("' + label(btn).slice(0, 40) + '")');
          }
          return out;
        },
        walls() {
          // A check counts only when a person would see it: drawn, on the page, not hidden or parked off-screen.
          // Pages that use reCAPTCHA keep its challenge frame loaded but hidden (visibility: hidden, 10,000 px up)
          // and its invisible badge at 0×0: those aren't asking anyone anything.
          const shown = (f) => {
            const r = f.getBoundingClientRect();
            if (r.width <= 100 || r.height <= 60) return false;
            if (r.bottom < -50 || r.right < -50 || r.top > document.documentElement.scrollHeight + 50) return false;
            if (f.checkVisibility && !f.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })) return false;
            for (let n = f; n && n.nodeType === 1; n = n.parentElement) { const st = style(n); if (st.visibility === 'hidden' || st.display === 'none' || +st.opacity < 0.1) return false; }
            return true;
          };
          const frames = [...document.querySelectorAll('iframe')].filter(shown).map((f) => f.src || '');
          const title = (document.title || '').toLowerCase();
          const text = (document.body && document.body.innerText || '').slice(0, 4000).toLowerCase();
          const found = [];
          if (frames.some((s) => /recaptcha/.test(s))) found.push('reCAPTCHA');
          if (frames.some((s) => /hcaptcha/.test(s))) found.push('hCaptcha');
          if (frames.some((s) => /challenges\.cloudflare\.com|turnstile/.test(s)) || /just a moment|checking your browser|attention required/.test(title)) found.push('Cloudflare check');
          if (/verify (that )?you('| a)re (a )?human|are you a robot|i'?m not a robot|unusual traffic from your computer|press (&|and) hold/.test(text)) found.push('human check');
          // A refusal no person can clear from here: a security block, or not offered where the browser is.
          if (/you have been blocked|access (is )?denied|request (was )?blocked|this (site|service|content|product) is (not available|unavailable) in your (country|region)|not available in your (country|region)|geo ?location/.test(title + ' ' + text.slice(0, 1500))) found.push('blocked by the site');
          return found;
        },
        // The text fields a person could type in now (shown and switched on), and which one has the caret.
        inputs() {
          const on = [];
          let focused = '';
          walk(document.documentElement, 0, 0, (el) => {
            if (!typable(el) || el.type === 'password' || !seen(el)) return;
            if (el.disabled || el.readOnly || el.getAttribute('aria-disabled') === 'true') return;
            on.push(refOf(el));
          });
          const a = deepActive(); if (a && typable(a) && !a.disabled) focused = clean(name(a)) || 'a field';
          // The buttons a person could press now: a page that waits on a click shows a new one.
          const buttons = [];
          walk(document.documentElement, 0, 0, (el) => {
            if (buttons.length >= 60 || !(el.tagName === 'BUTTON' || el.getAttribute('role') === 'button' || (el.tagName === 'INPUT' && /^(button|submit)$/.test(el.type)))) return;
            if (el.disabled || el.getAttribute('aria-disabled') === 'true' || !seen(el)) return;
            const n = clean(name(el)).slice(0, 40); if (n) buttons.push(n);
          });
          return { on, focused, names: on.slice(0, 3).map((r) => clean(name(find(r))) ), buttons };
        },
        // Whether something that opens (a menu, a dropdown, a section) says it's open: "true", "false", or null.
        expanded(ref) {
          const el = find(ref); if (!el) return null;
          for (let n = el, d = 0; n && d < 3; n = n.parentElement, d++) { const v = n.getAttribute && n.getAttribute('aria-expanded'); if (v != null) return v; }
          return null;
        },
        mark(ref, token) { const el = find(ref); if (!el) return false; el.setAttribute('data-sill-pick', token); return true; },
        markVaulted(ref) { const el = find(ref); if (el) vaulted.add(el); return !!el; },
        // Where an element is now (viewport CSS pixels), for a picture of just that part.
        rect(ref) {
          const el = find(ref); if (!el) return null;
          const f = face(el) || el; f.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
          const r = f.getBoundingClientRect(), off = offsets.get(el) || [0, 0];
          return { x: r.left + off[0], y: r.top + off[1], w: r.width, h: r.height };
        },
        // The page's repeated records (result cards, table rows, list items) as data: the biggest set of
        // siblings that look alike and carry text, each as its title, link and lines of text.
        records(max) {
          const best = recordSet();
          if (!best) return [];
          return best.filter((k) => clean(k.innerText)).slice(0, max || 200).map((k) => {
            const link = k.matches('a[href]') ? k : k.querySelector('a[href]');
            const head = k.querySelector('h1,h2,h3,h4,h5,[role=heading]');
            // The first lines, and any later one with a price or a total: a card's price often sits at its foot.
            const all = [...new Set((k.innerText || '').split('\n').map((l) => clean(l)).filter((l) => l))];
            const money = /[$€£¥₹]|\b(USD|EUR|GBP|AED|CAD|AUD|JPY|INR)\b|\b(total|per night|price)\b/i;
            const lines = all.slice(0, 15).concat(all.slice(15).filter((l) => money.test(l)).slice(0, 8)).map((l) => l.slice(0, 160));
            const img = k.querySelector('img[alt]');
            const out = { title: clean((head && head.innerText) || (link && link.innerText) || lines[0] || '').slice(0, 200), lines };
            if (link && link.href && !link.href.startsWith('javascript:')) out.url = link.href;
            if (img && img.alt) out.image = clean(img.alt).slice(0, 120);
            return out;
          });
        },
        absent(text) {
          const want = String(text).toLowerCase();
          return !(document.body && document.body.innerText || '').toLowerCase().includes(want);
        },
        // How many times the words show (the page's text, and what fields read): a wait for words
        // that were already there waits for more of them, not for nothing.
        textCount(text) {
          const want = String(text).toLowerCase();
          if (!want) return 0;
          const body = (document.body && document.body.innerText || '').toLowerCase();
          let n = 0, i = body.indexOf(want);
          while (i >= 0) { n++; i = body.indexOf(want, i + want.length); }
          walk(document.documentElement, 0, 0, (el) => { if (typable(el) && String(el.value || '').toLowerCase().includes(want)) n++; });
          if (!n && byText(text)) n = 1;
          return n;
        },
        present(selector, text) {
          if (selector) return !!deepQuery(selector);
          if (text) {
            const want = String(text).toLowerCase();
            if ((document.body && document.body.innerText || '').toLowerCase().includes(want) || byText(text)) return true;
            // What a field shows counts too ("New York" in the From box).
            let hit = false;
            walk(document.documentElement, 0, 0, (el) => { if (typable(el) && String(el.value || el.innerText || '').toLowerCase().includes(want)) { hit = true; return false; } });
            return hit;
          }
          return document.readyState === 'complete';
        },
      };
    })();
    """#
}
