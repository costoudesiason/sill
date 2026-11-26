import AppKit

// What an agent needs of a page beyond its own frame: frames in other
// processes (a Stripe card form, a "Sign in with Google" box) and custom
// elements with closed shadow roots. Neither can be reached by the page's
// own script, so Chromium is asked directly: every frame in another process
// is its own DevTools session (Target.setAutoAttach, flattened), where Sill's
// element script runs in a world of its own; and a closed shadow root's
// insides are read from the accessibility tree, which sees through them.
//
// Refs: "e12" is in the page (or a same-origin frame, or an open shadow
// root); "f2:e7" is element e7 in frame 2; "a913" is accessibility node 913.

@MainActor
final class AgentPage {
    private static var pages: [ObjectIdentifier: AgentPage] = [:]

    static func of(_ view: SillWebView) -> AgentPage {
        let key = ObjectIdentifier(view)
        if let page = pages[key], page.view === view { return page }
        let page = AgentPage(view)
        pages[key] = page
        pages = pages.filter { $0.value.view != nil }
        return page
    }

    struct Frame {
        let session: String
        let frameId: String
        let parent: String?   // the session of the frame it sits in; nil for the page
        var url: String
        var world: Int?
        let index: Int
    }

    private weak var view: SillWebView?
    private(set) var frames: [String: Frame] = [:]
    private var nextIndex = 1
    private var started = false
    private var dragWaiter: ((Any?) -> Void)?
    private var accessibility = false
    private var inFlight: [String: Date] = [:]
    private var requestURLs: [String: String] = [:]
    private var failures: [(at: Date, what: String)] = []
    /// Data requests the page has sent, all told: an action that sent none and changed nothing did nothing.
    private(set) var sent = 0

    /// The page's data requests that failed or were refused since `since`, said briefly.
    func failedRequests(since: Date) -> [String] {
        failures.removeAll { Date().timeIntervalSince($0.at) > 60 }
        return Array(failures.filter { $0.at >= since }.map(\.what).prefix(4))
    }

    private static func short(_ url: String) -> String {
        guard let u = URL(string: url) else { return String(url.prefix(80)) }
        return (u.host() ?? "") + String(u.path.prefix(60))
    }
    /// Frames found to hold nothing to act on, and when: not asked again for a while.
    private var emptyFrames: [String: Date] = [:]

    /// Page requests (fetch, XHR) started since `since` and still out; ones
    /// open for over 4 s (long polls, streams) don't count.
    func fetching(since: Date) -> Bool {
        let now = Date()
        inFlight = inFlight.filter { now.timeIntervalSince($0.value) < 4 }
        return inFlight.values.contains { $0 >= since.addingTimeInterval(-0.05) }
    }

    private init(_ view: SillWebView) { self.view = view }

    /// A request that only reports (analytics, logs, beacons, error and performance reporting).
    static func telemetry(_ url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        let host = (u.host() ?? "").lowercased(), path = u.path.lowercased()
        if host.range(of: #"(^|\.)(analytics|telemetry|metrics|stats|log|logs|logging|events?|track(ing)?|beacon|collect|rum|sentry|bat|px|pixel|sink)[.-]"#, options: .regularExpression) != nil { return true }
        return path.range(of: #"/(log|logs|logging|track|tracking|tracker|beacon|beacons|collect|collector|analytics|telemetry|metrics|stats|events?|pixel|impression|impressions|rum|perf|performance|error-?report|csp-report|ping|heartbeat|fe_?log|clientlog|js_?tracking|gen_204|generate_204|sink)(/|$|\.|_|-)"#, options: .regularExpression) != nil
    }

    /// Follows the page's frames from now on. Cheap: Chromium only says when frames come and go.
    func start() async {
        guard !started, let view else { return }
        started = true
        _ = try? await call("DOM.enable")
        // Requests the page makes (fetch, XHR): an action has settled only once
        // what it asked the network for has come back (suggestions, results).
        _ = try? await call("Network.enable", ["maxTotalBufferSize": 0, "maxResourceBufferSize": 0])
        view.devtoolsEvent = { [weak self] method, params, session in
            MainActor.assumeIsolated { self?.event(method, params as? [String: Any] ?? [:], session) }
        }
        _ = try? await call("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true])
        // Frames already there are reported at once; a moment for their events.
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private func event(_ method: String, _ params: [String: Any], _ session: String?) {
        switch method {
        case "Target.attachedToTarget":
            guard let child = params["sessionId"] as? String, let info = params["targetInfo"] as? [String: Any],
                  info["type"] as? String == "iframe", let id = info["targetId"] as? String else { return }
            frames[child] = Frame(session: child, frameId: id, parent: session, url: info["url"] as? String ?? "", world: nil, index: nextIndex)
            nextIndex += 1
            // Frames inside this frame, too.
            Task { _ = try? await self.call("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true], session: child) }
        case "Target.detachedFromTarget":
            if let child = params["sessionId"] as? String { frames[child] = nil }
        case "Target.targetInfoChanged":
            if let info = params["targetInfo"] as? [String: Any], let id = info["targetId"] as? String,
               let key = frames.first(where: { $0.value.frameId == id })?.key {
                frames[key]?.url = info["url"] as? String ?? ""
                frames[key]?.world = nil   // a new document: a new world to make
            }
        case "Network.requestWillBeSent" where session == nil:
            guard let id = params["requestId"] as? String,
                  ["XHR", "Fetch"].contains(params["type"] as? String ?? "") else { return }
            let url = (params["request"] as? [String: Any])?["url"] as? String ?? ""
            // Telemetry (logging, tracking, beacons, metrics) brings nothing to the page: an action isn't
            // waiting on it. Only requests that can bring content hold an action until they're back.
            if AgentPage.telemetry(url) { return }
            inFlight[id] = Date()
            requestURLs[id] = url
            sent += 1
        case "Network.responseReceived" where session == nil:
            // The page's own data requests that came back refused (403, a geo-block, a 500): worth saying.
            guard let id = params["requestId"] as? String, requestURLs[id] != nil,
                  let response = params["response"] as? [String: Any], let status = response["status"] as? Int, status >= 400 else { return }
            failures.append((Date(), "\(status) from \(Self.short(requestURLs[id] ?? ""))"))
        case "Network.loadingFinished" where session == nil:
            if let id = params["requestId"] as? String { inFlight[id] = nil; requestURLs[id] = nil }
        case "Network.loadingFailed" where session == nil:
            if let id = params["requestId"] as? String {
                inFlight[id] = nil
                // Ours to block (an ad, a tracker) or the page giving up on purpose isn't news; anything else is.
                if let url = requestURLs.removeValue(forKey: id), params["blockedReason"] == nil, params["canceled"] as? Bool != true {
                    failures.append((Date(), "failed (\(params["errorText"] as? String ?? "network error")) from \(Self.short(url))"))
                }
            }
        case "Input.dragIntercepted":
            dragWaiter?(params["data"])
            dragWaiter = nil
        default:
            break
        }
    }

    // MARK: DevTools

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:], session: String? = nil, timeout: Double = 8) async throws -> [String: Any] {
        guard let view else { throw AgentError("The page is gone.") }
        return try await withCheckedThrowingContinuation { continuation in
            var done = false
            view.devtools(method, params: params, session: session) { result, error in
                guard !done else { return }
                done = true
                if let result { continuation.resume(returning: result as? [String: Any] ?? [:]) }
                else { continuation.resume(throwing: AgentError(error ?? "\(method) failed.")) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                done = true
                continuation.resume(throwing: AgentError("\(method) took too long."))
            }
        }
    }

    /// Waits for Chromium to hand over a drag it intercepted (Input.setInterceptDrags).
    func nextDrag(timeout: Double) async -> Any? {
        await withCheckedContinuation { continuation in
            var done = false
            dragWaiter = { data in
                guard !done else { return }
                done = true
                continuation.resume(returning: data)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !done else { return }
                done = true
                self?.dragWaiter = nil
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: frames in other processes

    func frame(index: Int) -> Frame? { frames.values.first { $0.index == index } }

    /// Runs `expression` in Sill's own world inside the frame, with the element script there.
    func evaluate(_ expression: String, in frame: Frame, timeout: Double = 8) async throws -> Any? {
        for attempt in 0..<2 {
            var world = frames[frame.session]?.world
            if world == nil {
                let made = try await call("Page.createIsolatedWorld", ["frameId": frame.frameId, "worldName": "sill-agent",
                                                                        "grantUniveralAccess": false], session: frame.session, timeout: timeout)
                guard let id = made["executionContextId"] as? Int else { throw AgentError("Couldn't reach into the frame.") }
                frames[frame.session]?.world = id
                world = id
                _ = try await call("Runtime.evaluate", ["expression": AgentScript.source, "contextId": id], session: frame.session, timeout: timeout)
            }
            do {
                let answer = try await call("Runtime.evaluate", ["expression": expression, "contextId": world!, "returnByValue": true,
                                                                 "awaitPromise": true], session: frame.session, timeout: timeout)
                if let thrown = answer["exceptionDetails"] as? [String: Any] {
                    throw AgentError("Script failed in the frame: \((thrown["exception"] as? [String: Any])?["description"] ?? thrown["text"] ?? "")")
                }
                let value = (answer["result"] as? [String: Any])?["value"]
                return value is NSNull ? nil : value
            } catch let error as AgentError where attempt == 0 && error.message.lowercased().contains("context") {
                frames[frame.session]?.world = nil   // the frame moved on to a new document
            }
        }
        return nil
    }

    /// Where the frame's own (0, 0) is on the page, in CSS pixels; the frame
    /// scrolled into view in each frame it sits in, first.
    func offset(of frame: Frame, reveal: Bool) async throws -> (x: Double, y: Double) {
        var x = 0.0, y = 0.0
        var current: Frame? = frame
        while let f = current {
            let owner = try await call("DOM.getFrameOwner", ["frameId": f.frameId], session: f.parent)
            guard let node = owner["backendNodeId"] as? Int else { throw AgentError("Couldn't find the frame on the page.") }
            if reveal { _ = try? await call("DOM.scrollIntoViewIfNeeded", ["backendNodeId": node], session: f.parent) }
            let box = try await call("DOM.getBoxModel", ["backendNodeId": node], session: f.parent)
            guard let model = box["model"] as? [String: Any], let content = model["content"] as? [Double], content.count >= 2 else {
                throw AgentError("The frame isn't laid out.")
            }
            x += content[0]
            y += content[1]
            current = f.parent.flatMap { frames[$0] }
        }
        return (x, y)
    }

    /// The elements in every frame in another process, refs prefixed, boxes in
    /// page coordinates. Fast by design: frames too small to hold a control (ad
    /// and tracking frames) are skipped, the rest asked at once, each given half
    /// a second, and a frame with nothing in it isn't asked again for a while.
    /// Banners in frames from other sites (a consent service's own frame): turned down there, as on the page.
    /// Only frames big enough to be a banner, each given half a second.
    func clearFrames() async -> [String] {
        var out: [String] = []
        for frame in frames.values.sorted(by: { $0.index < $1.index }) {
            guard let at = try? await offsetAndSize(of: frame), at.w >= 200, at.h >= 80 else { continue }
            if let said = (try? await evaluate("window.__sillAgent.clearWay(true)", in: frame, timeout: 0.5)) as? [String] {
                out += said.map { $0 + " (in a frame from \(URL(string: frame.url)?.host ?? "another site"))" }
            }
        }
        return out
    }

    func frameElements(all: Bool) async -> [[String: Any]] {
        let now = Date()
        emptyFrames = emptyFrames.filter { now.timeIntervalSince($0.value) < 5 }
        let candidates = frames.values.filter { emptyFrames[$0.session] == nil }.sorted { $0.index < $1.index }
        var placed: [(Frame, (x: Double, y: Double))] = []
        for frame in candidates {
            guard let at = try? await offsetAndSize(of: frame), at.w >= 24, at.h >= 16 else {
                emptyFrames[frame.session] = now
                continue
            }
            placed.append((frame, (at.x, at.y)))
        }
        let results = await withTaskGroup(of: (Int, [[String: Any]]).self) { group -> [(Int, [[String: Any]])] in
            for (i, (frame, at)) in placed.enumerated() {
                group.addTask { @MainActor in
                    // The frame's own "how much more page" line is the frame's business, not the page's.
                    let items = ((try? await self.evaluate("window.__sillAgent.snapshot(\(all))", in: frame, timeout: 0.5)) as? [[String: Any]] ?? [])
                        .filter { $0["context"] as? String != "page" }
                    if items.isEmpty { self.emptyFrames[frame.session] = Date() }
                    return (i, items.map { item in
                        var item = item
                        if let ref = item["ref"] as? String { item["ref"] = "f\(frame.index):\(ref)" }
                        if var box = item["box"] as? [String: Any] {
                            box["x"] = (box["x"] as? Double ?? 0) + at.x
                            box["y"] = (box["y"] as? Double ?? 0) + at.y
                            item["box"] = box
                        }
                        item["inFrame"] = URL(string: frame.url)?.host ?? frame.url
                        return item
                    })
                }
            }
            var out: [(Int, [[String: Any]])] = []
            for await result in group { out.append(result) }
            return out
        }
        return results.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    /// The frame's place and size on the page (its owner element's content box).
    private func offsetAndSize(of frame: Frame) async throws -> (x: Double, y: Double, w: Double, h: Double) {
        let owner = try await call("DOM.getFrameOwner", ["frameId": frame.frameId], session: frame.parent, timeout: 0.5)
        guard let node = owner["backendNodeId"] as? Int else { throw AgentError("No owner.") }
        let box = try await call("DOM.getBoxModel", ["backendNodeId": node], session: frame.parent, timeout: 0.5)
        guard let model = box["model"] as? [String: Any], let c = model["content"] as? [Double], c.count >= 8 else { throw AgentError("No box.") }
        var x = c[0], y = c[1]
        if let parent = frame.parent.flatMap({ frames[$0] }) {
            let up = try await offset(of: parent, reveal: false)
            x += up.x; y += up.y
        }
        return (x, y, c[2] - c[0], c[5] - c[1])
    }

    // MARK: closed shadow roots, through the accessibility tree

    private static let actionable: Set<String> = ["button", "link", "textbox", "searchbox", "checkbox", "radio", "combobox",
                                                  "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "switch", "option",
                                                  "slider", "spinbutton", "treeitem", "listbox"]

    /// Interactive nodes inside the marked custom elements (data-sill-pick tokens).
    func hiddenElements(tokens: [String]) async -> [[String: Any]] {
        var out: [[String: Any]] = []
        if !accessibility {
            accessibility = true
            do { try await call("Accessibility.enable") } catch { NSLog("SillAgent: Accessibility.enable: \(error)") }
        }
        for token in tokens {
            let nodes: [[String: Any]]
            do {
                let found = try await call("Runtime.evaluate", ["expression": "document.querySelector('[data-sill-pick=\"\(token)\"]')"])
                guard let object = (found["result"] as? [String: Any])?["objectId"] as? String else { continue }
                // The host's subtree, closed shadow root included (the accessibility tree has no walls).
                let described = try await call("DOM.describeNode", ["objectId": object, "depth": 0, "pierce": true])
                let backend = (described["node"] as? [String: Any])?["backendNodeId"] as? Int
                let tree = try await call("Accessibility.getPartialAXTree", ["backendNodeId": backend ?? 0, "fetchRelatives": false])
                // The host's node, then down through its children (getChildAXNodes), breadth first.
                var all = tree["nodes"] as? [[String: Any]] ?? []
                var queue = all.compactMap { $0["nodeId"] as? String }
                var seen = Set(queue)
                while let id = queue.first, all.count < 300 {
                    queue.removeFirst()
                    let children = try await call("Accessibility.getChildAXNodes", ["id": id])
                    for child in children["nodes"] as? [[String: Any]] ?? [] {
                        guard let childId = child["nodeId"] as? String, !seen.contains(childId) else { continue }
                        seen.insert(childId)
                        all.append(child)
                        queue.append(childId)
                    }
                }
                nodes = all
            } catch {
                NSLog("SillAgent: closed shadow root \(token): \(error)")
                continue
            }
            _ = try? await call("Runtime.evaluate", ["expression": "document.querySelector('[data-sill-pick=\"\(token)\"]')?.removeAttribute('data-sill-pick')"])
            for node in nodes where node["ignored"] as? Bool != true {
                let role = (node["role"] as? [String: Any])?["value"] as? String ?? ""
                guard Self.actionable.contains(role), let backend = node["backendDOMNodeId"] as? Int,
                      let box = await box(of: backend) else { continue }
                let name = (node["name"] as? [String: Any])?["value"] as? String ?? ""
                out.append(["ref": "a\(backend)", "role": role, "name": String(name.prefix(120)),
                            "box": ["x": box.minX, "y": box.minY, "w": box.width, "h": box.height]])
            }
        }
        return out
    }

    func box(of backend: Int, reveal: Bool = false) async -> CGRect? {
        if reveal { _ = try? await call("DOM.scrollIntoViewIfNeeded", ["backendNodeId": backend]) }
        guard let box = try? await call("DOM.getBoxModel", ["backendNodeId": backend]),
              let model = box["model"] as? [String: Any], let q = model["border"] as? [Double], q.count >= 8 else { return nil }
        let xs = [q[0], q[2], q[4], q[6]], ys = [q[1], q[3], q[5], q[7]]
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}
