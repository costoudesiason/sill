import AppKit
import WebKit

// Agents on this Mac — Claude Code, Codex, a script — driving Sill, when you
// let them (Settings › Agents, off until you turn it on).
//
// Sill listens on a Unix socket, agent.sock in its own Application Support
// folder: the folder this user's alone (0700), the socket 0600, and every
// connection's other end checked to be this same user before a byte is read.
// Never on the network. `sill-mcp`, inside the app, is the MCP server an
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
        AppDelegate.shared.current?.toast("An agent connected to Sill")
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
            Task { @MainActor in
                var answer = await AgentCommands.run(request)
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
    static func run(_ request: [String: Any]) async -> [String: Any] {
        guard Preferences.shared.agentControl else { return ["ok": false, "error": "Agent control is off in Sill's settings."] }
        let command = request["cmd"] as? String ?? ""
        let args = request["args"] as? [String: Any] ?? [:]
        do {
            let result = try await perform(command, args)
            return ["ok": true, "result": result]
        } catch let error as AgentError {
            return ["ok": false, "error": error.message]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    // MARK: finding things

    private static var browsers: [BrowserWindowController] {
        AppDelegate.shared.browsers.filter { !$0.isPrivate && !$0.isPopup }
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
        ]
    }

    private static func tab(_ args: [String: Any]) throws -> (Tab, BrowserWindowController) {
        if let id = args["tab"] as? String {
            for browser in browsers {
                if let tab = browser.tabs.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) {
                    return (tab, browser)
                }
            }
            throw AgentError("No tab with id \(id). Call tabs.list for current ids.")
        }
        guard let browser = AppDelegate.shared.current.flatMap({ $0.isPrivate ? nil : $0 }) ?? browsers.last,
              let selected = browser.selected else { throw AgentError("No open tab. Use tabs.open first.") }
        return (selected, browser)
    }

    private static func webView(_ args: [String: Any]) throws -> (SillWebView, Tab, BrowserWindowController) {
        let (tab, browser) = try tab(args)
        return (tab.materialize(), tab, browser)
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

    private static func perform(_ command: String, _ args: [String: Any]) async throws -> Any {
        switch command {
        case "status":
            return ["app": "Sill", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    "windows": browsers.count, "tabs": browsers.reduce(0) { $0 + $1.tabs.count }]

        case "tabs.list":
            return browsers.flatMap { browser in browser.tabs.map { describe($0, in: browser) } }

        case "tabs.open":
            let url = try webURL(args["url"])
            let background = args["background"] as? Bool ?? false
            guard let browser = AppDelegate.shared.current.flatMap({ $0.isPrivate ? nil : $0 }) ?? browsers.last
                ?? Optional(AppDelegate.shared.makeBrowser(isPrivate: false)) else { throw AgentError("No window.") }
            browser.showWindow(nil)
            let tab = browser.addTab(url: url, select: !background)
            tab.openedByAgent = true
            if args["wait"] as? Bool ?? true { try await waitForLoad(tab, timeout: args["timeout"] as? Double ?? 20) }
            return describe(tab, in: browser)

        case "tabs.select":
            let (tab, browser) = try tab(args)
            browser.select(tab)
            browser.window?.makeKeyAndOrderFront(nil)
            return describe(tab, in: browser)

        case "tabs.close":
            let (tab, browser) = try tab(args)
            browser.close(tab)
            return ["closed": tab.id.uuidString]

        case "page.navigate":
            let url = try webURL(args["url"])
            let (tab, browser) = try tab(args)
            tab.load(url)
            if args["wait"] as? Bool ?? true { try await waitForLoad(tab, timeout: args["timeout"] as? Double ?? 20) }
            return describe(tab, in: browser)

        case "page.back", "page.forward", "page.reload", "page.stop":
            let (tab, browser) = try tab(args)
            switch command {
            case "page.back": tab.goBack()
            case "page.forward": tab.goForward()
            case "page.reload": tab.reload()
            default: tab.stop()
            }
            if command != "page.stop", args["wait"] as? Bool ?? true {
                try await Task.sleep(nanoseconds: 150_000_000)
                try await waitForLoad(tab, timeout: args["timeout"] as? Double ?? 20)
            }
            return describe(tab, in: browser)

        case "page.wait":
            let (tab, browser) = try tab(args)
            let timeout = args["timeout"] as? Double ?? 20
            if let selector = args["selector"] as? String {
                try await waitFor(selector: selector, text: nil, in: tab.materialize(), timeout: timeout)
            } else if let text = args["text"] as? String {
                try await waitFor(selector: nil, text: text, in: tab.materialize(), timeout: timeout)
            } else {
                try await waitForLoad(tab, timeout: timeout)
            }
            return describe(tab, in: browser)

        case "page.text":
            let (view, _, _) = try webView(args)
            let limit = args["maxChars"] as? Int ?? 40_000
            let text = try await evaluate("return (document.body ? document.body.innerText : '')", in: view, world: Web.world) as? String ?? ""
            return ["url": view.url?.absoluteString ?? "", "title": view.title ?? "",
                    "text": String(text.prefix(limit)), "truncated": text.count > limit]

        case "page.snapshot":
            let (view, _, _) = try webView(args)
            let all = args["all"] as? Bool ?? false
            let result = try await evaluate("return window.__sillAgent.snapshot(all)", in: view, world: Web.world, arguments: ["all": all])
            return ["url": view.url?.absoluteString ?? "", "title": view.title ?? "", "elements": result ?? []]

        case "page.click":
            let (view, tab, browser) = try webView(args)
            let target = try await locate(args, in: view)
            if view.window != nil, tab === browser.selected || browser.split?.contains(tab) == true, args["real"] as? Bool ?? true {
                realClick(at: target.point, in: view, double: args["double"] as? Bool ?? false)
            } else {
                _ = try await evaluate("return window.__sillAgent.click(ref)", in: view, world: Web.world, arguments: ["ref": target.ref])
            }
            try await Task.sleep(nanoseconds: 120_000_000)
            return ["clicked": target.ref, "url": view.url?.absoluteString ?? ""]

        case "page.type":
            let (view, _, _) = try webView(args)
            guard let text = args["text"] as? String else { throw AgentError("Missing \"text\".") }
            // Here "text" is what to type; the field is found by ref, selector or its label.
            let target = try await locate(["ref": args["ref"] as Any, "selector": args["selector"] as Any,
                                           "text": args["label"] as Any], in: view)
            let done = try await evaluate("return window.__sillAgent.type(ref, text, clear)", in: view, world: Web.world,
                                          arguments: ["ref": target.ref, "text": text, "clear": args["clear"] as? Bool ?? true])
            if args["submit"] as? Bool ?? false { press("Enter", in: view) }
            return ["typed": done ?? false]

        case "page.select":
            let (view, _, _) = try webView(args)
            guard let value = args["value"] as? String else { throw AgentError("Missing \"value\".") }
            let target = try await locate(args, in: view)
            let chosen = try await evaluate("return window.__sillAgent.choose(ref, value)", in: view, world: Web.world,
                                            arguments: ["ref": target.ref, "value": value])
            return ["selected": chosen ?? false]

        case "page.press":
            let (view, _, _) = try webView(args)
            guard let key = args["key"] as? String else { throw AgentError("Missing \"key\".") }
            guard press(key, in: view) else {
                throw AgentError("Unknown key \(key). Use Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp/Down/Left/Right, PageUp, PageDown, Home, End.")
            }
            return ["pressed": key]

        case "page.scroll":
            let (view, _, _) = try webView(args)
            if args["ref"] != nil || args["selector"] != nil || args["text"] != nil {
                let target = try await locate(args, in: view)
                return ["scrolledTo": target.ref]
            }
            let dy = args["dy"] as? Double ?? 600
            _ = try await evaluate("window.scrollBy({top: dy, behavior: 'instant'}); return window.scrollY", in: view, world: Web.world,
                                   arguments: ["dy": dy])
            return ["scrolled": dy]

        case "page.eval":
            let (view, _, _) = try webView(args)
            guard let script = args["script"] as? String else { throw AgentError("Missing \"script\" (a function body; use return).") }
            let value = try await evaluate(script, in: view, world: .page)
            return ["value": sanitize(value)]

        case "page.screenshot":
            let (view, _, _) = try webView(args)
            let configuration = WKSnapshotConfiguration()
            if let width = args["maxWidth"] as? Double { configuration.snapshotWidth = NSNumber(value: min(width, Double(view.bounds.width))) }
            let image = try await view.takeSnapshot(configuration: configuration)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw AgentError("The page couldn't be captured.") }
            return ["png": png.base64EncodedString(), "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh]

        case "page.find":
            let (view, _, _) = try webView(args)
            guard let text = args["text"] as? String else { throw AgentError("Missing \"text\".") }
            let configuration = WKFindConfiguration()
            configuration.caseSensitive = false
            let found = try await view.find(text, configuration: configuration)
            return ["found": found.matchFound]

        case "history.search":
            let query = args["query"] as? String ?? ""
            let limit = args["limit"] as? Int ?? 20
            let visits = query.isEmpty ? History.shared.recent(limit: limit) : History.shared.search(query, limit: limit)
            return visits.map { ["url": $0.url, "title": $0.title, "visits": $0.count,
                                 "last": ISO8601DateFormatter().string(from: $0.last)] }

        default:
            throw AgentError("Unknown command \"\(command)\". Commands: status, tabs.list, tabs.open, tabs.select, tabs.close, page.navigate, page.back, page.forward, page.reload, page.stop, page.wait, page.text, page.snapshot, page.click, page.type, page.select, page.press, page.scroll, page.eval, page.screenshot, page.find, history.search.")
        }
    }

    // MARK: helpers

    private static func evaluate(_ body: String, in view: WKWebView, world: WKContentWorld,
                                 arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: AgentError("Script failed: \(error.localizedDescription)"))
                }
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

    private static func waitFor(selector: String?, text: String?, in view: WKWebView, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = try? await evaluate("return window.__sillAgent.present(selector, text)", in: view, world: Web.world,
                                            arguments: ["selector": selector ?? NSNull(), "text": text ?? NSNull()]) as? Bool
            if found == true { return }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        throw AgentError("Timed out after \(Int(timeout)) s waiting for \(selector ?? text ?? "it").")
    }

    /// The element named by ref, CSS selector or visible text, scrolled into
    /// view, with its centre in the web view's coordinates.
    private static func locate(_ args: [String: Any], in view: WKWebView) async throws -> (ref: String, point: NSPoint) {
        let found = try await evaluate("return window.__sillAgent.locate(ref, selector, text)", in: view, world: Web.world, arguments: [
            "ref": args["ref"] as? String ?? NSNull(), "selector": args["selector"] as? String ?? NSNull(),
            "text": args["text"] as? String ?? NSNull(),
        ]) as? [String: Any]
        guard let found, let ref = found["ref"] as? String else {
            throw AgentError("No element matched. Use page.snapshot for refs, or give a CSS selector or its visible text.")
        }
        let zoom = view.pageZoom * view.magnification
        let x = CGFloat((found["x"] as? Double) ?? 0) * zoom
        let y = CGFloat((found["y"] as? Double) ?? 0) * zoom + view.obscuredContentInsets.top
        return (ref, NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y))
    }

    /// A real click, as a hand would make it: pages see trusted events.
    private static func realClick(at point: NSPoint, in view: WKWebView, double: Bool) {
        guard let window = view.window else { return }
        let location = view.convert(point, to: nil)
        for count in 1...(double ? 2 : 1) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0) {
                    if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
                }
            }
        }
    }

    @discardableResult
    private static func press(_ key: String, in view: WKWebView) -> Bool {
        let keys: [String: (UInt16, String)] = [
            "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"),
            "backspace": (51, "\u{7f}"), "delete": (117, String(UnicodeScalar(NSDeleteFunctionKey)!)), "space": (49, " "),
            "arrowup": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)), "arrowdown": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)),
            "arrowleft": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)), "arrowright": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
            "pageup": (116, String(UnicodeScalar(NSPageUpFunctionKey)!)), "pagedown": (121, String(UnicodeScalar(NSPageDownFunctionKey)!)),
            "home": (115, String(UnicodeScalar(NSHomeFunctionKey)!)), "end": (119, String(UnicodeScalar(NSEndFunctionKey)!)),
        ]
        guard let (code, characters) = keys[key.lowercased()] else { return false }
        let window = view.window
        view.window?.makeFirstResponder(view)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window?.windowNumber ?? 0, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
        return true
    }
}

// MARK: - The page side

enum AgentScript {
    /// Runs in Sill's own world: refs for interactive elements, and the
    /// actions on them. Never reads the value of a password field.
    static let source = #"""
    (() => {
      if (window.__sillAgent) return;
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
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        if (r.width < 1 || r.height < 1) return false;
        const s = getComputedStyle(el);
        return s.visibility !== 'hidden' && s.display !== 'none' && s.opacity !== '0';
      };
      const interactive = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch],[role=combobox],[role=textbox],[contenteditable=""],[contenteditable=true],[onclick],[tabindex]:not([tabindex="-1"])';
      const name = (el) => {
        const label = el.getAttribute('aria-label') || (el.labels && el.labels[0] && el.labels[0].innerText) || el.getAttribute('alt')
          || el.getAttribute('title') || el.getAttribute('placeholder') || (el.innerText || el.textContent || '');
        return String(label).replace(/\s+/g, ' ').trim().slice(0, 120);
      };
      const role = (el) => el.getAttribute('role') || ({ A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', SUMMARY: 'button' }[el.tagName])
        || (el.tagName === 'INPUT' ? (['checkbox', 'radio', 'submit', 'button', 'range', 'file'].includes(el.type) ? el.type : 'textbox') : (el.isContentEditable ? 'textbox' : 'generic'));
      const describe = (el) => {
        const r = el.getBoundingClientRect();
        const item = { ref: refOf(el), role: role(el), name: name(el), tag: el.tagName.toLowerCase(),
          box: { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) } };
        if (el.href) item.href = el.href;
        if (el.type) item.type = el.type;
        if ('value' in el && el.type !== 'password' && el.tagName !== 'BUTTON') item.value = String(el.value).slice(0, 200);
        if (el.type === 'password') item.value = el.value ? '(hidden)' : '';
        if ('checked' in el && (el.type === 'checkbox' || el.type === 'radio')) item.checked = el.checked;
        if (el.disabled) item.disabled = true;
        if (document.activeElement === el) item.focused = true;
        return item;
      };
      const locate = (ref, selector, text) => {
        let el = ref ? find(ref) : null;
        if (!el && selector) el = document.querySelector(selector);
        if (!el && text) {
          const want = String(text).toLowerCase();
          el = [...document.querySelectorAll(interactive)].find((e) => visible(e) && name(e).toLowerCase() === want)
            || [...document.querySelectorAll(interactive)].find((e) => visible(e) && name(e).toLowerCase().includes(want));
        }
        return el;
      };
      const set = (el, value) => {
        const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      };
      window.__sillAgent = {
        snapshot(all) {
          const out = [];
          for (const el of document.querySelectorAll(interactive)) {
            if (!visible(el)) continue;
            if (!all) { const r = el.getBoundingClientRect(); if (r.bottom < -200 || r.top > innerHeight + 1200) continue; }
            out.push(describe(el));
            if (out.length >= 400) break;
          }
          return out;
        },
        locate(ref, selector, text) {
          const el = locate(ref, selector, text);
          if (!el) return null;
          el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
          const r = el.getBoundingClientRect();
          return { ref: refOf(el), x: r.left + r.width / 2, y: r.top + r.height / 2 };
        },
        click(ref) { const el = find(ref); if (!el) return false; el.focus && el.focus(); el.click(); return true; },
        type(ref, text, clear) {
          const el = find(ref); if (!el) return false;
          el.focus();
          if (el.isContentEditable) {
            if (clear) { document.execCommand('selectAll'); document.execCommand('delete'); }
            document.execCommand('insertText', false, text);
            return true;
          }
          set(el, (clear ? '' : el.value) + text);
          return true;
        },
        choose(ref, value) {
          const el = find(ref); if (!el || el.tagName !== 'SELECT') return false;
          const option = [...el.options].find((o) => o.value === value || o.text.trim() === value);
          if (!option) return false;
          el.value = option.value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        },
        present(selector, text) {
          if (selector) return !!document.querySelector(selector);
          if (text) return (document.body && document.body.innerText || '').toLowerCase().includes(String(text).toLowerCase());
          return document.readyState === 'complete';
        },
      };
    })();
    """#
}
