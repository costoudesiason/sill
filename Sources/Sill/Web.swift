import AppKit
import WebKit
@_exported import SillEngine

/// What every page shares: one content controller with Sill's scripts, run
/// in a world of their own the page can't see or tamper with, and one router
/// for what they say back.
@MainActor
enum Web {
    static let world = WKContentWorld.world(name: "sill")
    static let router = MessageRouter()

    static let controller: WKUserContentController = {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: PageScripts.main, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
        // What agents use to read and act on a page (AgentControl.swift), in
        // Sill's own world where pages can't see or change it.
        controller.addUserScript(WKUserScript(source: AgentScript.source, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: world))
        controller.add(router, contentWorld: world, name: "sill")
        return controller
    }()

    /// One pool of web processes for every page, set up the way Safari's is.
    /// A pool made the public way keeps nothing ready: each new site starts a
    /// process from nothing and each one left is thrown away. This one keeps
    /// a started process waiting for the next page, and keeps the processes
    /// of sites lately left, so going back to one finds it still running.
    /// WebKit sizes both to the Mac's memory and drops them under pressure.
    /// The settings are outside the public framework, so each is asked for
    /// by name; without them the pool is an ordinary one.
    static let pool: WKProcessPool = {
        let pool = makePool()
        cacheAsABrowser(pool)
        return pool
    }()

    private static func makePool() -> WKProcessPool {
        let make = NSSelectorFromString("_initWithConfiguration:")
        guard let settingsClass = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type,
              WKProcessPool.instancesRespond(to: make)
        else { return WKProcessPool() }
        let settings = settingsClass.init()
        for (key, setter) in [("usesWebProcessCache", "setUsesWebProcessCache:"),
                              ("prewarmsProcessesAutomatically", "setPrewarmsProcessesAutomatically:")]
        where settings.responds(to: NSSelectorFromString(setter)) {
            settings.setValue(true, forKey: key)
        }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Init = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let alloc = NSSelectorFromString("alloc")
        guard let allocate = class_getClassMethod(WKProcessPool.self, alloc),
              let initialise = class_getInstanceMethod(WKProcessPool.self, make)
        else { return WKProcessPool() }
        let empty = unsafeBitCast(method_getImplementation(allocate), to: Alloc.self)(WKProcessPool.self, alloc)
        let made = unsafeBitCast(method_getImplementation(initialise), to: Init.self)(empty, make, settings)
        return (made?.takeRetainedValue() as? WKProcessPool) ?? WKProcessPool()
    }

    /// WebKit sizes its caches by what kind of app it's in, and an app that
    /// doesn't say gets a document browser's: a small disk cache for the
    /// network, small memory caches in each page's process, and no process
    /// cache at all (the pool's setting above is then ignored: WebKit logs
    /// "cache model is not PrimaryWebBrowser"). Safari says it is the primary
    /// web browser, and so does Sill. Measured: a page on a site whose tab
    /// had just closed loaded in the kept process, a fifth sooner (about 420
    /// ms against 515, three runs each); the larger caches aren't in that.
    /// Only WebKit's C interface can say it, so each name is looked up, and
    /// the model is read back first: anything unexpected leaves it alone.
    /// Before any page exists, so the process cache is sized with it.
    private static func cacheAsABrowser(_ pool: WKProcessPool) {
        let objectSelector = NSSelectorFromString("_apiObject")
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        // (The pool's own object must still come back as a pointer.)
        guard pool.responds(to: objectSelector),
              let method = class_getInstanceMethod(WKProcessPool.self, objectSelector),
              let types = method_getTypeEncoding(method), types.pointee == 94,  // "^"
              let setter = dlsym(everywhere, "WKContextSetCacheModel"),
              let getter = dlsym(everywhere, "WKContextGetCacheModel")
        else { return }
        typealias Object = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
        typealias GetModel = @convention(c) (UnsafeRawPointer) -> UInt32
        typealias SetModel = @convention(c) (UnsafeRawPointer, UInt32) -> Void
        guard let context = unsafeBitCast(pool.method(for: objectSelector), to: Object.self)(pool, objectSelector) else { return }
        // kWKCacheModelDocumentViewer, DocumentBrowser, PrimaryWebBrowser.
        let primaryWebBrowser: UInt32 = 2
        let model = unsafeBitCast(getter, to: GetModel.self)(context)
        guard model < primaryWebBrowser else { return }
        unsafeBitCast(setter, to: SetModel.self)(context, primaryWebBrowser)
    }

    /// Starts the first web process while the window is still being built,
    /// so the first page doesn't wait for one. The first of a launch is by
    /// far the slowest to start.
    static func warm() {
        let start = NSSelectorFromString("_warmInitialProcess")
        if pool.responds(to: start) { pool.perform(start) }
    }

    /// WebKit keeps the process of a page that has gone (its tab closed or
    /// put to sleep) for the site's next page, for half an hour, with some
    /// of what the page had allocated still in it. Measured: five tabs
    /// closed (Wikipedia, BBC News, apple.com, GitHub, the New York Times)
    /// left 594 MB in their kept processes, 45 to 235 MB each, against
    /// 1,270 MB while open; going back to a site in its kept process loads
    /// the page about a fifth sooner (cacheAsABrowser).
    ///
    /// After a tab is closed they're kept for three minutes from when tabs
    /// stopped going: time for ⇧⌘T, or the same site again from the palette
    /// or a link, to start in one. A tab put to sleep or a window closed is
    /// Sill giving memory back, so then they go after half a minute, and a
    /// close doesn't put that off. The Mac short of memory lets them go at
    /// once (App.swift). The process started for the next page is not one
    /// of them. A site's service worker outlives its page by some seconds
    /// and only then is its process kept, hence the second pass.
    static func releaseIdleProcesses(soon: Bool = true) {
        let clear = NSSelectorFromString("_clearWebProcessCache")
        guard pool.responds(to: clear) else { return }
        if !soon, let soonDue, soonDue > Date() { return }
        releases.forEach { $0.cancel() }
        soonDue = soon ? Date().addingTimeInterval(30) : nil
        releases = (soon ? [30, 50] : [180, 200]).map { delay in
            let work = DispatchWorkItem { pool.perform(clear) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }
    private static var releases: [DispatchWorkItem] = []
    /// When a release asked for by a sleep or a window closing is due.
    private static var soonDue: Date?

    /// The Mac is short of memory: every kept process goes now.
    static func releaseIdleProcessesNow() {
        let clear = NSSelectorFromString("_clearWebProcessCache")
        guard pool.responds(to: clear) else { return }
        releases.forEach { $0.cancel() }
        releases = []
        soonDue = nil
        pool.perform(clear)
    }

    /// Private windows share one cookie jar for as long as Sill runs, and it is never written down.
    static let privateStore = WKWebsiteDataStore.nonPersistent()

    /// Safari's own version, so sites serve WebKit what they serve Safari.
    static let applicationName: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    /// Backspace edits text and nothing else: WebKit's old habit of going back
    /// a page on Backspace (Safari dropped it) would throw away a half-filled form.
    static func backspaceStays(_ preferences: WKPreferences) {
        let set = NSSelectorFromString("_setBackspaceKeyNavigationEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, false)
    }

    /// Scrolling that glides, as Chromium's does: a mouse wheel's steps and
    /// the arrow, space and page keys animate instead of jumping. WebKit
    /// has both (its "Scroll animator" and smooth keyboard scrolling) but
    /// leaves them off; trackpads keep the system's own momentum either way.
    /// The features are asked for by name; a WebKit without them is as before.
    private static let smoothFeatures: [NSObject] = {
        let list = NSSelectorFromString("_features")
        guard WKPreferences.responds(to: list),
              let all = WKPreferences.perform(list)?.takeUnretainedValue() as? [NSObject] else { return [] }
        // Only the keys: WebKit's scroll animator, tried for the wheel, eases
        // every scroll toward where it's headed, which a trackpad feels as
        // drag. Safari leaves it off too.
        let wanted: Set<String> = ["EventHandlerDrivenSmoothKeyboardScrollingEnabled"]
        return all.filter { ($0.value(forKey: "key") as? String).map(wanted.contains) ?? false }
    }()

    static func smoothScrolling(_ preferences: WKPreferences) {
        let set = NSSelectorFromString("_setEnabled:forFeature:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
        let call = unsafeBitCast(preferences.method(for: set), to: Setter.self)
        for feature in smoothFeatures { call(preferences, set, true, feature) }
    }

    /// What a page view is made with: on Chromium only whether it's private
    /// counts. Two kept, made once, so no WebKit machinery starts for them.
    /// A copy each time: what one caller changes is never seen by the next.
    static func configuration(private isPrivate: Bool) -> WKWebViewConfiguration {
        (isPrivate ? privateMarker : normalMarker).copy() as! WKWebViewConfiguration
    }
    private static let normalMarker = WKWebViewConfiguration()
    private static let privateMarker: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }()

    /// A WebKit setting outside the public framework, if this WebKit has it.
    private static func set(_ preferences: WKPreferences, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard preferences.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, value)
    }
}

/// The web view, knowing which tab it belongs to.
/// A tab's page: Chromium (SillEngine) behind the members Sill used on
/// WebKit's view, so the rest of Sill reads the same. What WebKit needed
/// help with and Chromium does itself (a first frame held back, pages drawn
/// ahead, a hung process ended by hand) is kept as no-ops.
final class SillWebView: SEWebView {
    weak var tab: Tab?

    /// Made for a WebKit configuration, as before: only whether it's private counts now.
    convenience init(frame: NSRect, configuration: WKWebViewConfiguration) {
        self.init(frame: frame, private: !configuration.websiteDataStore.isPersistent)
    }

    /// Behind the page: its own background colour (white until it says),
    /// seen only where a resized page hasn't yet drawn its new size.
    var backdrop: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) {
        didSet { if backdrop != oldValue { layer?.backgroundColor = backdrop } }
    }

    // Chromium answers for its own processes.
    var processIsResponsive: Bool { true }
    func endProcess() { reload() }
    func processStoppedAnswering() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pageHidden = !isShown && !keepsDrawing
        if isShown && !agentAtWork { tab?.pageShown() }
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        pageHidden = !isShown
        // An agent's page under the one in front isn't seen: its dialogs wait.
        if isShown && !agentAtWork { tab?.pageShown() }
    }
    override func viewDidHide() {
        super.viewDidHide()
        pageHidden = !keepsDrawing
    }

    /// The page being left stays over the one coming in until that has drawn;
    /// for that moment it is only a picture, and clicks go to the new page.
    var outgoing = false
    override func hitTest(_ point: NSPoint) -> NSView? { outgoing ? nil : super.hitTest(point) }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        outgoing = false
    }

    var isShown: Bool { window != nil && !isHidden }

    /// Its video is in picture in picture: it stays in the window, drawn,
    /// under the page in front, so Chromium keeps decoding it.
    var floating = false {
        didSet {
            if floating { isHidden = false; autoresizingMask = [.width, .height] }
            pageHidden = !keepsDrawing && !isShown
        }
    }

    /// An agent is working in it out of sight (AgentControl): like a floating
    /// video, it stays in the window, drawn, under the page in front, so its
    /// screenshots, animations and timers run as if it were in front.
    var agentAtWork = false {
        didSet {
            guard agentAtWork != oldValue else { return }
            if agentAtWork { isHidden = false; autoresizingMask = [.width, .height] }
            pageHidden = !keepsDrawing && !isShown
        }
    }

    /// Drawn though out of sight: a floating video, or an agent's page.
    var keepsDrawing: Bool { floating || agentAtWork }

    /// Put aside where it is, hidden: Chromium stops drawing it.
    func park() {
        if keepsDrawing {
            superview?.addSubview(self, positioned: .below, relativeTo: nil)
            return
        }
        drawingAhead = false
        guard !isHidden else { return }
        isHidden = true
        outgoing = false
        autoresizingMask = []
    }

    var shownBefore = false
    var laidOutUnseen = false
    /// Drawn ahead out of sight (⌘T's top hit, a tab about to come in):
    /// its loads leave the keys where they are.
    private(set) var drawingAhead = false {
        didSet { takesFocusOnLoad = !drawingAhead }
    }
    /// Under the page in front, drawing, until it's put aside (park) or comes in.
    func startDrawingAhead() { drawingAhead = true }
    func cameIntoView() {
        drawingAhead = false
        if isShown { tab?.pageShown() }
    }
    /// Once the page has drawn a frame since now (two animation frames
    /// in the page, then one for the window to show it), or after `limit`,
    /// whichever comes first: a page coming in stays under the one being
    /// left until then, so nothing blank shows between them.
    /// `settle`: how long after the page has drawn before `run`, for its
    /// frame to reach the screen (it goes through the GPU process first).
    func afterNextFrame(within limit: TimeInterval = 0.25, settle: TimeInterval = 0.017, _ run: @escaping () -> Void) {
        var done = false
        let finish = {
            guard !done else { return }
            done = true
            run()
        }
        evaluateJavaScript("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(true))))", completion: { _, error in
            // No page to ask yet: the limit decides, not the failure.
            guard error == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { MainActor.assumeIsolated { finish() } }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { MainActor.assumeIsolated { finish() } }
    }
    var isFullyIn: Bool { true }
    static let firstFrame: UInt = 1 << 1
    /// Unseen until it has drawn its first frame (white, otherwise, for a
    /// moment: bright in dark mode). Still in the window and drawing, only
    /// transparent: Chromium draws a page it thinks is shown. It shows once
    /// the page is under way and has drawn, or after a second and a half.
    func holdForFirstFrame() {
        guard heldWatch == nil else { return }
        alphaValue = 0
        heldWatch = observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, view.estimatedProgress >= 0.3 || !view.isLoading else { return }
                self.afterNextFrame(within: 0.5) { [weak self] in self?.showFirstFrame() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showFirstFrame() }
    }
    func showFirstFrame(laidOut: Bool = true) {
        guard heldWatch != nil else { return }
        heldWatch = nil
        alphaValue = 1
    }
    private var heldWatch: NSKeyValueObservation?

    // MARK: WebKit's names, on Chromium

    var allowsBackForwardNavigationGestures = true
    var allowsMagnification = true
    var allowsLinkPreview = true
    var isInspectable = true
    var magnification: CGFloat {
        get { CGFloat(pageZoom) }
        set { pageZoom = Double(newValue) }
    }
    var interactionState: Any? {
        get { nil }
        set {}
    }
    var fullscreenState: WKWebView.FullscreenState { .notInFullscreen }
    var cameraCaptureState: WKMediaCaptureState { .none }
    var microphoneCaptureState: WKMediaCaptureState { .none }

    @discardableResult
    func load(_ request: URLRequest) -> Any? {
        if let url = request.url { loadURL(url) }
        return nil
    }

    func evaluateJavaScript(_ script: String, in frame: WKFrameInfo?, in world: WKContentWorld,
                            completionHandler: ((Result<Any, Error>) -> Void)? = nil) {
        evaluateJavaScript(script, completion: { value, error in
            if let error { completionHandler?(.failure(error)) } else { completionHandler?(.success(value ?? NSNull())) }
        })
    }

    /// `body` runs as an async function's, its arguments named as given.
    func callAsyncJavaScript(_ body: String, arguments: [String: Any] = [:], in frame: WKFrameInfo?, in world: WKContentWorld,
                             completionHandler: ((Result<Any, Error>) -> Void)? = nil) {
        let names = arguments.keys.sorted()
        let values = names.map { name -> String in
            guard let value = arguments[name], JSONSerialization.isValidJSONObject([value]),
                  let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let text = String(data: data, encoding: .utf8) else { return "null" }
            return String(text.dropFirst().dropLast())
        }
        let script = "(async (\(names.joined(separator: ", "))) => {\n\(body)\n})(\(values.joined(separator: ", ")))"
        evaluateJavaScript(script, in: frame, in: world, completionHandler: completionHandler)
    }

    func callAsyncJavaScript(_ body: String, arguments: [String: Any] = [:], contentWorld: WKContentWorld) async throws -> Any? {
        try await withCheckedThrowingContinuation { done in
            callAsyncJavaScript(body, arguments: arguments, in: nil, in: contentWorld) { result in
                switch result {
                case .success(let value): done.resume(returning: value is NSNull ? nil : value)
                case .failure(let error): done.resume(throwing: error)
                }
            }
        }
    }

    func takeSnapshot(with configuration: WKSnapshotConfiguration?, completionHandler: @escaping (NSImage?, Error?) -> Void) {
        let width = configuration?.snapshotWidth.map { CGFloat(truncating: $0) } ?? bounds.width
        takeSnapshot(withWidth: width) { image in completionHandler(image, nil) }
    }

    func takeSnapshot(configuration: WKSnapshotConfiguration?) async throws -> NSImage {
        try await withCheckedThrowingContinuation { done in
            takeSnapshot(with: configuration) { image, _ in
                if let image { done.resume(returning: image) } else { done.resume(throwing: CocoaError(.featureUnsupported)) }
            }
        }
    }

    func pauseAllMediaPlayback(completionHandler: (() -> Void)? = nil) {
        evaluateJavaScript("document.querySelectorAll('video, audio').forEach(m => m.pause())", completion: { _, _ in completionHandler?() })
    }
    func closeAllMediaPresentations(completionHandler: (() -> Void)? = nil) {
        evaluateJavaScript("document.pictureInPictureElement && document.exitPictureInPicture()", completion: { _, _ in completionHandler?() })
    }
    /// Symbols for the right-click menu's items, by their titles.
    static let menuSymbols: [String: String] = [
        "Open link in new tab": "plus.square.on.square", "Open Link in New Tab": "plus.square.on.square",
        "Copy link address": "link", "Copy Link Address": "link", "Copy": "doc.on.doc", "Paste": "doc.on.clipboard",
        "Cut": "scissors", "Select all": "selection.pin.in.out", "Select All": "selection.pin.in.out",
        "Back": "chevron.backward", "Forward": "chevron.forward", "Reload": "arrow.clockwise",
        "Inspect": "hammer", "Inspect Element": "hammer", "Save as…": "square.and.arrow.down", "Print…": "printer",
        "Copy image": "photo", "Copy Image": "photo", "Save image as…": "square.and.arrow.down",
        "Open image in new tab": "photo.on.rectangle", "Copy image address": "link", "View page source": "doc.text",
        "View Source": "doc.text", "Undo": "arrow.uturn.backward", "Redo": "arrow.uturn.forward",
    ]

    /// Finding in the page, as WebKit's find did: the next match is selected
    /// and scrolled to; whether there was one comes back.
    struct FindResult { let matchFound: Bool }
    func find(_ string: String, configuration: WKFindConfiguration? = nil, completionHandler: @escaping (FindResult) -> Void) {
        let backwards = configuration?.backwards ?? false
        let args = (try? JSONSerialization.data(withJSONObject: [string])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        evaluateJavaScript("window.find(\(args)[0], false, \(backwards), true, false, false, false)", completion: { value, _ in
            completionHandler(FindResult(matchFound: (value as? Bool) ?? false))
        })
    }
    func find(_ string: String, configuration: WKFindConfiguration? = nil) async -> FindResult {
        await withCheckedContinuation { done in find(string, configuration: configuration) { done.resume(returning: $0) } }
    }

    func setAllMediaPlaybackSuspended(_ suspended: Bool, completionHandler: (() -> Void)? = nil) {
        audioMuted = suspended
        completionHandler?()
    }
}

/// A sign-in box the person just clicked, as the page script saw it.
struct LoginField {
    enum Kind: String { case username, password, newPassword = "new", code }
    let kind: Kind
    /// In CSS pixels from the viewport's top-left.
    let rect: CGRect
    let byKeyboard: Bool
}

final class MessageRouter: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let tab = (message.webView as? SillWebView)?.tab,
              let body = message.body as? [String: Any]
        else { return }
        Self.route(body, to: tab)
    }

    /// "rgb(r, g, b)" or an opaque "rgba(r, g, b, a)", as getComputedStyle gives it.
    static func color(css: String) -> CGColor? {
        let parts = css.split { !"0123456789.".contains($0) }.compactMap { Double($0) }
        guard parts.count >= 3, parts.count == 3 || parts[3] >= 0.99 else { return nil }
        return CGColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }

    static func route(_ body: [String: Any], to tab: Tab) {
        guard let type = body["t"] as? String else { return }
        switch type {
        case "hover":
            tab.hovered(link: body["href"] as? String)
        case "open":
            if let href = body["href"] as? String, let url = URL(string: href),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                tab.middleClicked(url, shift: (body["shift"] as? Bool) ?? false)
            }
        case "scroll":
            tab.scrolled((body["v"] as? Bool) ?? false)
        case "media":
            tab.mediaChanged((body["playing"] as? Bool) ?? false)
        case "audible":
            tab.audible = (body["on"] as? Bool) ?? false
        case "backdrop":
            if let text = body["c"] as? String, let color = Self.color(css: text) { tab.webView?.backdrop = color }
        case "click":
            if let role = body["role"] as? String, let name = body["name"] as? String {
                Habits.shared.clicked(in: tab, role: role, name: name, href: body["href"] as? String)
            }
        case "went":
            if let href = body["href"] as? String, let url = URL(string: href) {
                Habits.shared.went(tab, to: url, title: body["title"] as? String)
            }
        case "pipReturn":
            // Back from the floating window: to its tab, its window, to the front.
            tab.host?.bringBack(tab)
        case "credentials":
            guard let password = body["password"] as? String, !password.isEmpty else { return }
            tab.signedIn(user: (body["user"] as? String) ?? "", password: password)
        case "icon":
            if let href = body["href"] as? String, let url = URL(string: href) { tab.found(icon: url) }
        case "field":
            guard let kind = (body["kind"] as? String).flatMap(LoginField.Kind.init(rawValue:)) else { return }
            func number(_ key: String) -> CGFloat { CGFloat((body[key] as? NSNumber)?.doubleValue ?? 0) }
            let field = LoginField(kind: kind, rect: CGRect(x: number("x"), y: number("y"), width: number("w"), height: number("h")),
                                   byKeyboard: (body["how"] as? String) == "key")
            tab.focused(field)
        default:
            break
        }
    }
}

enum PageScripts {
    /// Link hover for the status pill, the page's icon, and sign-in boxes for
    /// Apple Passwords. Main frame only; it reads, and only writes into a
    /// field when Sill is asked to fill one.
    static let main = #"""
    (() => {
      if (window.__sill) return;
      window.__sill = true;
      // To Sill: on Chromium through the function Sill's helper gives the
      // page (taken now, before any of the page's own scripts run).
      const send = window.__sillPost;
      const post = (m) => { try { if (send) send(JSON.stringify(m)); else webkit.messageHandlers.sill.postMessage(m); } catch (_) {} };

      // On Chromium: no background ("conditional") passkey prompt. Chromium
      // answers it with a bubble of its own over sign-in boxes ("Use Passkey
      // from another device") that covers Sill's Passwords menu and can't
      // finish in Sill. Sites asking for it are told it isn't there.
      if (send && window.PublicKeyCredential) {
        try {
          Object.defineProperty(PublicKeyCredential, 'isConditionalMediationAvailable', { value: async () => false, configurable: true });
          const get = navigator.credentials.get.bind(navigator.credentials);
          navigator.credentials.get = function (options) {
            if (options && options.mediation === 'conditional') return Promise.reject(new DOMException('Not supported', 'NotSupportedError'));
            return get(options);
          };
        } catch (_) {}
      }

      // Links under the pointer.
      let hovered = null;
      // While the page scrolls, links pass under a still pointer many times
      // a second; the preview waits for the scroll to settle.
      let wanted = null, settle = 0, scrolledAt = 0;
      const tell = () => { if (wanted !== hovered) { hovered = wanted; post({ t: 'hover', href: wanted }); } };
      const hover = (href) => {
        wanted = href;
        clearTimeout(settle);
        const wait = 150 - (performance.now() - scrolledAt);
        if (wait > 0) settle = setTimeout(tell, wait); else tell();
      };
      addEventListener('scroll', () => { scrolledAt = performance.now(); }, { passive: true, capture: true });
      document.addEventListener('mouseover', (e) => {
        // Only the pointer itself: an event the page made up is not a hover.
        if (!e.isTrusted) return;
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        hover(a && a.href && !a.href.startsWith('javascript:') ? a.href : null);
      }, true);
      document.addEventListener('mouseout', (e) => { if (!e.relatedTarget) hover(null); }, true);

      // The middle button on a link: WebKit tells the browser nothing, so
      // the link is handed over here and opened in a tab of its own.
      const linkAt = (e) => (e.target && e.target.closest ? e.target.closest('a[href]') : null);
      document.addEventListener('mousedown', (e) => { if (e.button === 1 && linkAt(e)) e.preventDefault(); }, true);
      document.addEventListener('auxclick', (e) => {
        const a = linkAt(e);
        if (e.button !== 1 || !a || !a.href || a.href.startsWith('javascript:')) return;
        e.preventDefault();
        e.stopPropagation();
        post({ t: 'open', href: a.href, shift: e.shiftKey });
      }, true);

      // Nothing here reads the page's scroll position: read in a scroll
      // event, after the page's own handlers have changed the page, it can
      // make the page lay itself out an extra time on every frame of a scroll.

      // Whether a video is playing, so switching tabs asks only pages that
      // have one to float it. Media events don't bubble; capture sees them.
      let playing = false;
      const media = () => {
        const now = [...document.querySelectorAll('video')].some(v => {
          if (v.paused || v.ended || v.readyState < 2 || v.muted || v.volume === 0) return false;
          const box = v.getBoundingClientRect();
          return box.width >= 200 && box.height >= 112;
        });
        if (now !== playing) { playing = now; post({ t: 'media', playing: now }); }
        // Anything making sound (Chromium doesn't tell Sill; WebKit did).
        const loud = [...document.querySelectorAll('video, audio')].some(m => !m.paused && !m.ended && !m.muted && m.volume > 0);
        if (loud !== audible) { audible = loud; post({ t: 'audible', on: loud }); }
      };
      let audible = false;
      ['playing', 'pause', 'ended', 'emptied', 'volumechange'].forEach(e => document.addEventListener(e, media, true));
      media();

      // The page's own background colour, behind the page in Sill: where
      // a page being resized hasn't drawn its new width yet, that colour
      // shows rather than the window. Read once loaded, never per frame.
      if (window.top === window) {
        let backdrop = '';
        const shade = () => {
          const read = el => el ? getComputedStyle(el).backgroundColor : '';
          const solid = c => c && !/^rgba\(.*,\s*0\)$/.test(c) && c !== 'transparent';
          const c = [read(document.documentElement), read(document.body)].find(solid) || 'rgb(255, 255, 255)';
          if (c !== backdrop) { backdrop = c; post({ t: 'backdrop', c }); }
        };
        if (document.readyState === 'complete') shade(); else addEventListener('load', shade, { once: true });
        matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => setTimeout(shade, 100));
      }

      // The float's return button: the video leaves picture in picture still
      // playing (its close button pauses it). Sill brings this tab back.
      const left = (e) => {
        const v = e.target;
        if (!(v instanceof HTMLVideoElement)) return;
        setTimeout(() => {
          const floating = document.pictureInPictureElement === v || v.webkitPresentationMode === 'picture-in-picture';
          if (!floating && !v.paused && !v.ended) post({ t: 'pipReturn' });
        }, 60);
      };
      document.addEventListener('leavepictureinpicture', left, true);
      // Only a video that was floating has come back: the same event tells
      // of one going full screen, and bringing its tab back then takes the
      // page out of the full-screen window, leaving it black.
      const floated = new WeakSet();
      document.addEventListener('webkitpresentationmodechanged', (e) => {
        const v = e.target;
        if (!(v instanceof HTMLVideoElement)) return;
        if (v.webkitPresentationMode === 'picture-in-picture') floated.add(v);
        else if (v.webkitPresentationMode === 'inline' && floated.delete(v)) left(e);
      }, true);

      // The page's icon: the one nearest 64 px, an SVG, or /favicon.ico.
      const icon = () => {
        let best = null, bestScore = -1;
        for (const l of document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="apple-touch-icon-precomposed"]')) {
          if (!l.href) continue;
          const sizes = (l.getAttribute('sizes') || '').toLowerCase();
          const svg = /svg/.test(l.type || '') || /\.svg(\?|$)/.test(l.href);
          let size = svg || sizes === 'any' ? 64 : parseInt(sizes, 10) || (/apple-touch/.test(l.rel) ? 180 : 16);
          const score = 1000 - Math.abs(size - 64) + (svg ? 5 : 0);
          if (score > bestScore) { best = l.href; bestScore = score; }
        }
        post({ t: 'icon', href: best || new URL('/favicon.ico', location.href).href });
      };
      if (document.readyState === 'complete') icon(); else addEventListener('load', icon, { once: true });

      // Sign-in boxes.
      const textual = (el) => el instanceof HTMLInputElement && ['text', 'email', 'tel', ''].includes(el.type);
      const hints = (el) => [el.name, el.id, el.placeholder, el.getAttribute('aria-label'), el.autocomplete].join(' ').toLowerCase();
      const isPassword = (el) => el instanceof HTMLInputElement && el.type === 'password';
      const isCode = (el) => el instanceof HTMLInputElement && (el.autocomplete === 'one-time-code'
        || (textual(el) && /\b(otp|totp|2fa|mfa|one.?time|verification.?code|security.?code|auth.?code)\b/.test(hints(el))));
      const isUser = (el) => textual(el) && (/(username|email|webauthn)/.test(el.autocomplete || '')
        || /(user|e-?mail|login|account|identifier|phone)/.test(hints(el)));
      const scope = (el) => el.form || el.closest('form') || document;
      const shown = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'; };
      const kindOf = (el) => {
        if (isPassword(el)) return el.autocomplete === 'new-password' ? 'new' : 'password';
        if (isCode(el)) return 'code';
        if (!isUser(el)) return null;
        if (scope(el).querySelector('input[type=password]') || /(username|webauthn)/.test(el.autocomplete || '')) return 'username';
        if (/(e-?mail|user|login|identifier)/.test(hints(el)) && el.form) return 'username';
        return null;
      };
      const report = (el, how) => {
        const kind = kindOf(el);
        if (!kind) return;
        const r = el.getBoundingClientRect();
        post({ t: 'field', kind, how, x: r.left, y: r.top, w: r.width, h: r.height });
      };
      document.addEventListener('mousedown', (e) => {
        const el = e.target;
        if (el instanceof HTMLInputElement && e.button === 0) setTimeout(() => report(el, 'click'), 0);
      }, true);
      document.addEventListener('keydown', (e) => {
        const el = document.activeElement;
        if (e.key === 'ArrowDown' && !e.altKey && !e.metaKey && el instanceof HTMLInputElement && !el.value) report(el, 'key');
      }, true);

      const set = (input, value) => {
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        input.focus();
        setter.call(input, value);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      };
      window.__sillFill = (user, password) => {
        const el = document.activeElement;
        const inputs = [...scope(el || document.body).querySelectorAll('input')].filter(shown);
        const pw = (el && isPassword(el)) ? el : inputs.find(isPassword);
        let u = (el && (isUser(el) || (textual(el) && !isCode(el)))) ? el : null;
        if (!u && pw) {
          const i = inputs.indexOf(pw);
          for (let j = i - 1; j >= 0; j--) if (textual(inputs[j])) { u = inputs[j]; break; }
        }
        if (!u) u = inputs.find(isUser);
        if (u && user != null) set(u, user);
        if (pw && password != null) set(pw, password);
        if (pw && password != null) pw.focus();
        return !!(u || pw);
      };
      // A sign-in being sent: the name and password typed, for Sill to offer
      // to keep (it asks only once the sign-in has gone through). Only what
      // the person did (trusted events). Sent again only with a different
      // password (a second try after a wrong one). A name typed on a step
      // before the password's (email, then password) is remembered as soon
      // as it's left, for the step after.
      let sentPassword = null;
      const rememberUser = (u) => { try { if (u && u.value) sessionStorage.setItem('__sillUser', u.value); } catch (_) {} };
      document.addEventListener('change', (e) => { if (e.isTrusted && isUser(e.target)) rememberUser(e.target); }, true);
      const signingIn = (root) => {
        const area = root && root.querySelectorAll ? root : document;
        const pw = [...area.querySelectorAll('input[type=password]')].find((i) => i.value && shown(i) && i.autocomplete !== 'one-time-code');
        if (!pw) {
          rememberUser([...area.querySelectorAll('input')].find((i) => isUser(i) && i.value && shown(i)));
          return;
        }
        if (pw.value === sentPassword) return;
        const inputs = [...scope(pw).querySelectorAll('input')].filter(shown);
        let user = '';
        for (let j = inputs.indexOf(pw) - 1; j >= 0; j--) if (textual(inputs[j]) && inputs[j].value) { user = inputs[j].value; break; }
        if (!user) { const u = inputs.find((i) => isUser(i) && i.value); if (u) user = u.value; }
        if (!user) try { user = sessionStorage.getItem('__sillUser') || ''; } catch (_) {}
        sentPassword = pw.value;
        post({ t: 'credentials', user, password: pw.value });
      };
      document.addEventListener('submit', (e) => { if (e.isTrusted) signingIn(e.target); }, true);
      document.addEventListener('click', (e) => {
        const b = e.isTrusted && e.target.closest ? e.target.closest('button, input[type=submit], [role=button]') : null;
        if (b) setTimeout(() => signingIn(scope(b)), 0);
      }, true);
      document.addEventListener('keydown', (e) => {
        if (e.isTrusted && e.key === 'Enter' && e.target instanceof HTMLInputElement) signingIn(scope(e.target));
      }, true);

      // What you click, for Habits.swift: the thing's role and visible name
      // (never a field, never what's typed), and the address it led to when
      // the page changes its own. Sill skips private windows and agents' tabs.
      const clickable = 'a[href], button, summary, input[type=submit], input[type=button], input[type=checkbox], input[type=radio], ' +
        '[role=button], [role=link], [role=tab], [role=menuitem], [role=menuitemradio], [role=menuitemcheckbox], [role=option], [role=treeitem], [role=switch], [role=checkbox], [role=radio]';
      const roles = { A: 'link', BUTTON: 'button', SUMMARY: 'button', INPUT: 'button' };
      const named = (el) => {
        const label = el.getAttribute('aria-label') || el.getAttribute('title') || '';
        if (label.trim()) return label;
        const by = el.getAttribute('aria-labelledby');
        if (by) { const t = by.split(/\s+/).map((id) => document.getElementById(id)?.innerText || '').join(' '); if (t.trim()) return t; }
        const text = (el.innerText || '').trim().split('\n').find((l) => l.trim()) || '';
        if (text) return text;
        if (el instanceof HTMLInputElement && (el.type === 'submit' || el.type === 'button')) return el.value;
        const img = el.querySelector && el.querySelector('img[alt], svg[aria-label]');
        return img ? (img.getAttribute('alt') || img.getAttribute('aria-label') || '') : '';
      };
      document.addEventListener('click', (e) => {
        if (!e.isTrusted) return;
        const start = e.composedPath ? e.composedPath()[0] : e.target;
        const el = start && start.closest ? start.closest(clickable) : null;
        if (!el || el.isContentEditable) return;
        const type = el instanceof HTMLInputElement ? el.type : '';
        const role = el.getAttribute('role') || (type === 'checkbox' || type === 'radio' ? type : roles[el.tagName]) || 'button';
        const name = named(el).replace(/\s+/g, ' ').trim().slice(0, 80);
        if (!name) return;
        const before = location.href;
        post({ t: 'click', role, name, href: el instanceof HTMLAnchorElement ? el.href : null });
        for (const ms of [400, 1200, 3000]) setTimeout(() => {
          if (location.href !== before) post({ t: 'went', href: location.href, title: document.title });
        }, ms);
      }, true);

      window.__sillFillCode = (code) => {
        const el = document.activeElement;
        if (!(el instanceof HTMLInputElement)) return false;
        const boxes = el.maxLength === 1 ? [...scope(el).querySelectorAll('input')].filter((i) => i.maxLength === 1 && shown(i)) : [];
        if (boxes.length >= code.length) { [...code].forEach((c, i) => set(boxes[i], c)); return true; }
        set(el, code);
        return true;
      };
    })();
    """#
}

// MARK: - Favicons

/// Site icons, by host: in memory, on disk in Caches, fetched once per icon
/// address. Decoding and writing happen off the main thread; the main
/// thread only files the finished image.
@MainActor
final class Favicons {
    static let shared = Favicons()
    private var memory: [String: NSImage] = [:]
    /// Where each host's icon in memory came from: the same address again needs no fetch.
    private var source: [String: URL] = [:]
    private var inflight: [String: [(NSImage?) -> Void]] = [:]
    /// Once every icon on disk is in memory, nothing is read from disk again.
    private var preloaded = false
    /// Icons the preload has decoded and not yet handed to the main thread:
    /// a tab restored while it is still running takes its icon from here
    /// rather than reading and decoding the file itself.
    private let staged = Staged()

    private final class Staged: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: NSImage]? = [:]
        /// Left once every file has been read: the main thread may wait on it, briefly.
        let read = DispatchGroup()
        func put(_ key: String, _ image: NSImage) { lock.withLock { images?[key] = image } }
        func image(_ key: String) -> NSImage? { lock.withLock { images?[key] } }
        /// Everything read, handed over once; nothing is staged after.
        func drain() -> [String: NSImage] { lock.withLock { defer { images = nil }; return images ?? [:] } }
    }
    /// Run once the preload has landed: tabs asked for an icon it hadn't reached yet.
    private var afterPreload: [() -> Void] = []
    private let folder = Places.caches.appendingPathComponent("Icons", isDirectory: true)
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.httpAdditionalHeaders = ["Accept": "image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8"]
        return URLSession(configuration: configuration)
    }()

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func key(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    private func file(_ key: String) -> URL {
        folder.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))
    }

    /// Every icon on disk, decoded in the background, into memory: tabs and
    /// palette rows then never read or decode one on the main thread.
    func preload() {
        let folder = folder
        let staged = staged
        staged.read.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in files {
                guard let data = try? Data(contentsOf: url), let (image, _) = Self.decode(data, storing: false) else { continue }
                staged.put(url.lastPathComponent, image)
            }
            staged.read.leave()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.landed() }
            }
        }
    }

    /// Files what the preload found, once: from its own hop to the main
    /// thread, or sooner from settle().
    private func landed() {
        guard !preloaded else { return }
        for (key, image) in staged.drain() where memory[key] == nil { memory[key] = image }
        preloaded = true
        let waiting = afterPreload
        afterPreload = []
        waiting.forEach { $0() }
    }

    /// Before tabs are restored: waits up to `limit` for the preload (300
    /// icons take about 120 ms to read, measured), so they come up with
    /// their icons; tabs made after that take what has been read so far,
    /// and the rest when it lands (whenPreloaded), never a file of their own.
    func settle(within limit: TimeInterval) {
        guard !preloaded, staged.read.wait(timeout: .now() + limit) == .success else { return }
        // Everything is staged: taken now, the preload's own hop finds it done.
        landed()
    }

    /// Runs `work` once every icon on disk is in memory: at once if it is.
    func whenPreloaded(_ work: @escaping () -> Void) {
        if preloaded { work() } else { afterPreload.append(work) }
    }

    func cached(for page: URL?) -> NSImage? {
        guard let key = key(page) else { return nil }
        if let image = memory[key] { return image }
        if preloaded { return nil }
        if let image = staged.image(key.replacingOccurrences(of: "/", with: "_")) {
            memory[key] = image
            return image
        }
        // Asked before the preload has reached it: nothing yet, and no file
        // read here. Reading and decoding one cost the main thread about
        // 0.6 ms (measured), for every tab of a restored window.
        return nil
    }

    func fetch(page: URL, icon: URL, done: @escaping (NSImage?) -> Void) {
        guard let key = key(page) else { return done(nil) }
        if let image = memory[key], source[key] == icon { return done(image) }
        if inflight[key] != nil { inflight[key]?.append(done); return }
        inflight[key] = [done]
        var request = URLRequest(url: icon)
        request.cachePolicy = .returnCacheDataElseLoad
        let file = file(key)
        session.dataTask(with: request) { [weak self] data, response, _ in
            // On the session's own queue: decode, shrink and write here.
            var made: NSImage?
            if let data, (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, let (image, stored) = Self.decode(data) {
                made = image
                try? stored.write(to: file, options: .atomic)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let made {
                        self.memory[key] = made
                        self.source[key] = icon
                    }
                    let waiting = self.inflight.removeValue(forKey: key) ?? []
                    waiting.forEach { $0(made ?? self.memory[key]) }
                }
            }
        }.resume()
    }

    /// An icon from whatever a site serves, at no more than 64 px, and what
    /// to keep on disk: a small PNG, or the file itself for what ImageIO
    /// can't read (SVG).
    nonisolated private static func decode(_ data: Data, storing: Bool = true) -> (NSImage, Data)? {
        let options = [kCGImageSourceThumbnailMaxPixelSize: 64,
                       kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
            guard thumbnail.width >= 8 else { return nil }
            let png = NSMutableData()
            if storing, let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, thumbnail, nil)
                CGImageDestinationFinalize(destination)
            }
            let image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            return (image, png.length > 0 ? png as Data : data)
        }
        guard let image = NSImage(data: data), image.size.width >= 8 else { return nil }
        return (image, data)
    }
}


// MARK: - Picture in Picture

/// Leaving a tab that is playing a video takes the video with you, floating
/// in macOS's own picture in picture window, as Safari does; coming back
/// puts it back in the page.
///
/// Two things make it work. WebKit lets a page into picture in picture on
/// macOS only with a preference outside the public framework, off by default
/// in any app but Safari: without it the page is told PiP isn't there at
/// all. And WebKit wants a user gesture: a script the app runs with
/// evaluateJavaScript counts as one, but only for its synchronous part, so
/// the scripts below never await. They run in Sill's world; the videos are
/// the same elements there, as the DOM is shared between worlds.
///
/// Sill's scripts see the main frame only, so a video embedded from another
/// site (an iframe) doesn't float by itself; youtube.com, Netflix and Twitch
/// play theirs in the main frame.
@MainActor
/// Picture in picture on Chromium, in Apple's own floating window.
///
/// Chromium can't hand its video to AVKit, so the page sends it: a small
/// script draws each new frame of the video (scaled to at most 960 wide, on
/// the GPU) and passes the pixels to Sill's page-process function, which
/// puts them in shared memory for Sill (Tools/chromium-helper.mm). Here they
/// become sample buffers for AVKit's sample-buffer picture in picture, whose
/// play/pause, skip and return buttons drive the video in the page. The
/// page stays in the window, under the one in front, so Chromium keeps
/// decoding it. A video another site serves without letting pages read it,
/// or one under DRM, can't be drawn, and doesn't float.
enum PictureInPicture {
    static func allow(_ preferences: WKPreferences) {}

    /// The largest video playing, pumped to Sill. "in", or "none".
    fileprivate static let pump = """
    (() => {
      // Where the picture is on the page, in CSS pixels, as the video
      // draws it (letterboxed inside its box): the float flies from there.
      const place = (v) => {
        const b = v.getBoundingClientRect(), a = (v.videoWidth / v.videoHeight) || (16 / 9);
        let w = b.width, h = w / a;
        if (h > b.height) { h = b.height; w = h * a; }
        return JSON.stringify({ x: b.left + (b.width - w) / 2, y: b.top + (b.height - h) / 2, w, h });
      };
      if (window.__sillPip && window.__sillPip.on) return place(window.__sillPip.v);
      if (typeof __sillPipFrame !== 'function') return 'none';
      let best = null, area = 0;
      for (const v of document.querySelectorAll('video')) {
        if (v.paused || v.ended || v.readyState < 2 || v.muted || v.volume === 0) continue;
        const b = v.getBoundingClientRect();
        if (b.width < 200 || b.height < 112) continue;
        if (b.width * b.height >= area) { area = b.width * b.height; best = v; }
      }
      if (!best) return 'none';
      const v = best, pip = { on: true, v };
      let W = 0, H = 0, canvas = null, ctx = null;
      const state = () => [v.currentTime || 0, isFinite(v.duration) ? v.duration : 0, v.paused];
      const send = () => {
        if (!pip.on) return;
        const w = v.videoWidth, h = v.videoHeight;
        if (!w || !h) return;
        const scale = Math.min(1, (pip.max || 720) / w);
        const nw = Math.max(2, Math.round(w * scale) & ~1), nh = Math.max(2, Math.round(h * scale) & ~1);
        if (nw !== W || nh !== H) { W = nw; H = nh; canvas = new OffscreenCanvas(W, H); ctx = canvas.getContext('2d', { willReadFrequently: true, alpha: false }); }
        try {
          ctx.drawImage(v, 0, 0, W, H);
          __sillPipFrame(ctx.getImageData(0, 0, W, H).data.buffer, W, H, ...state());
        } catch (e) { pip.on = false; __sillPipFrame(null, 0, 0, 0, 0, true); }
      };
      const each = () => { if (!pip.on) return; send(); v.requestVideoFrameCallback(each); };
      v.requestVideoFrameCallback(each);
      send();
      // Paused, no frames come: the state still does, twice a second.
      pip.beat = setInterval(() => { if (pip.on && v.paused) __sillPipFrame(null, 0, 0, ...state()); }, 500);
      pip.stop = () => { pip.on = false; clearInterval(pip.beat); };
      window.__sillPip = pip;
      return place(v);
    })()
    """

    fileprivate static let stopPump = "(() => { const p = window.__sillPip; if (p) { p.stop(); window.__sillPip = null; } })()"

    /// `done(true)` once the video floats, `done(false)` at once when nothing could.
    static func leave(_ tab: Tab, done: @escaping (Bool) -> Void) {
        guard let webView = tab.webView, let window = tab.host?.window else { return done(false) }
        webView.evaluateJavaScript(pump, completion: { value, _ in
            MainActor.assumeIsolated {
                guard let json = value as? String, json != "none", let data = json.data(using: .utf8),
                      let place = try? JSONDecoder().decode(Place.self, from: data) else { return done(false) }
                // CSS pixels to the window's points, flipped: AppKit counts up from the bottom.
                let zoom = webView.pageZoom > 0 ? webView.pageZoom : 1
                let inView = NSRect(x: place.x * zoom, y: webView.bounds.height - (place.y + place.h) * zoom,
                                    width: place.w * zoom, height: place.h * zoom)
                let inWindow = window.contentView?.convert(inView, from: webView) ?? inView
                Floating.shared.start(tab, in: window, from: inWindow, done: done)
            }
        })
    }

    private struct Place: Decodable { let x, y, w, h: Double }

    /// Back into the page: the floating window closes.
    static func `return`(to tab: Tab) {
        Floating.shared.stop(tab)
    }

    static func frame(from tab: Tab, rgba: UnsafeRawPointer?, width: Int, height: Int, time: Double, duration: Double, paused: Bool) {
        Floating.shared.frame(from: tab, rgba: rgba, width: width, height: height, time: time, duration: duration, paused: paused)
    }
}

import AVKit
import Accelerate
import CoreMedia

/// The one video floating, and AVKit's window for it.
///
/// The frames go into a sample-buffer layer that sits in the window exactly
/// where the video is on the page, under everything: AVKit flies the float
/// out of that spot and back into it. The layer's clock follows the
/// video's, so the window's play button, its skip buttons and its progress
/// show the video as it is.
@MainActor
final class Floating: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = Floating()

    private(set) weak var tab: Tab?
    private var holder: NSView?
    private var layer: AVSampleBufferDisplayLayer?
    private var timebase: CMTimebase?
    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    private var started: ((Bool) -> Void)?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var format: CMVideoFormatDescription?
    private var paused = false
    private var duration = 0.0
    private var frames = 0
    /// AVKit is putting the float back (its return button, or the tab chosen again).
    private var returning = false
    /// AVKit's floating panel, the layer host in it showing our video, and
    /// what keeps that scaled to the panel while it floats.
    private weak var panel: NSWindow?
    private weak var host: CALayer?
    private var opening: CFRunLoopObserver?
    /// Its page's window covered by another app: Chromium hides the page,
    /// and a hidden page gives no frames. It is shown again.
    private var covered: NSObjectProtocol?
    private var resized: NSObjectProtocol?
    /// AVKit's flight in is over: the float shows.
    private var landed = false

    var isFloating: Bool { controller?.isPictureInPictureActive == true }

    func start(_ tab: Tab, in window: NSWindow, from place: NSRect, done: @escaping (Bool) -> Void) {
        end()
        self.tab = tab
        started = done
        frames = 0
        paused = false
        duration = 0
        returning = false
        landed = false
        // The layer AVKit takes the picture from sits exactly where the
        // float was last left: macOS flies a float out of its source, so from
        // there to there it just appears.
        let aspect = place.width > 1 && place.height > 1 ? place.width / place.height : 16 / 9
        let spot = Self.spot(aspect: aspect, near: window)
        // In the browser window (a layer of its own window draws nothing in
        // the float), at the float's spot, under everything there is.
        let inWindow = window.convertFromScreen(spot)
        let holder = NSView(frame: window.contentView?.convert(inWindow, from: nil) ?? inWindow)
        holder.wantsLayer = true
        window.contentView?.addSubview(holder, positioned: .below, relativeTo: nil)
        let layer = AVSampleBufferDisplayLayer()
        layer.frame = holder.bounds
        layer.videoGravity = .resizeAspect
        layer.preventsDisplaySleepDuringVideoPlayback = true
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 0)
            layer.controlTimebase = timebase
        }
        self.timebase = timebase
        holder.layer?.addSublayer(layer)
        self.holder = holder
        self.layer = layer
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
        controller.delegate = self
        self.controller = controller
        tab.webView?.floating = true
        covered = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // After Chromium has had its say on the same notification.
                DispatchQueue.main.async { self?.tab?.webView?.insistShown() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.tab?.webView?.insistShown() }
            }
        }
        // Floats once AVKit has frames to size its window by (started with
        // none, it works its size out as NaN and AppKit stops the app); if
        // it never can, the page is let go.
        possible = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.startWhenReady() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak tab] in
            guard let self, let tab, self.tab === tab, self.started != nil, !self.isFloating else { return }
            self.end()
        }
    }

    private func finish(_ floated: Bool) {
        guard let started else { return }
        self.started = nil
        started(floated)
    }

    /// Back into the page, for `tab` (nil: whatever is floating). The float
    /// flies back into its spot; then everything goes.
    func stop(_ tab: Tab?) {
        guard self.tab != nil, tab == nil || tab === self.tab else { return }
        // Back to the tab: the float just goes, where it is. Its source
        // gone first, there is nowhere for macOS to fly it back to.
        remember()
        holder?.removeFromSuperview()
        end()
    }

    /// Everything goes at once, without the flight back.
    private func end() {
        guard tab != nil || controller != nil else { return }
        let was = tab
        possible = nil
        landed = false
        untrack()
        if let covered { NotificationCenter.default.removeObserver(covered); self.covered = nil }
        controller?.delegate = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller = nil
        layer?.sampleBufferRenderer.flush()
        holder?.removeFromSuperview()
        holder = nil
        layer = nil
        timebase = nil
        tab = nil
        pool = nil
        format = nil
        returning = false
        finish(false)
        guard let was, let view = was.webView else { return }
        view.evaluateJavaScript(PictureInPicture.stopPump, completion: nil)
        view.floating = false
        (was.host as? BrowserWindowController)?.floatEnded(was)
    }

    func frame(from tab: Tab, rgba: UnsafeRawPointer?, width: Int, height: Int, time: Double, duration: Double, paused: Bool) {
        guard tab === self.tab, let layer else { return }
        follow(time: time, duration: duration, paused: paused)
        guard let rgba, width > 0, height > 0, let buffer = pixelBuffer(width, height) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: rgba), height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            var target = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                       rowBytes: CVPixelBufferGetBytesPerRow(buffer))
            // RGBA → BGRA
            let map: [UInt8] = [2, 1, 0, 3]
            vImagePermuteChannels_ARGB8888(&source, &target, map, vImage_Flags(kvImageNoFlags))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if format == nil || CMVideoFormatDescriptionGetDimensions(format!).width != Int32(width)
            || CMVideoFormatDescriptionGetDimensions(format!).height != Int32(height) {
            var made: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &made)
            format = made
        }
        guard let format else { return }
        let now = timebase.map(CMTimebaseGetTime) ?? CMTime(seconds: time, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
        frames += 1
        if frames == 1 { startWhenReady() }
    }

    /// The layer's clock kept on the video's: running while it plays, at
    /// its time, so AVKit's progress and buttons match the page.
    private func follow(time: Double, duration: Double, paused: Bool) {
        var changed = false
        let length = duration.isFinite && duration > 0 ? duration : 0
        if abs(length - self.duration) > 1 { self.duration = length; changed = true }
        if paused != self.paused { self.paused = paused; changed = true }
        if let timebase {
            CMTimebaseSetRate(timebase, rate: paused ? 0 : 1)
            let at = CMTimebaseGetTime(timebase).seconds
            if !at.isFinite || abs(at - time) > 0.3 {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: time, preferredTimescale: 600))
                changed = true
            }
        }
        if changed { controller?.invalidatePlaybackState() }
    }

    private func startWhenReady() {
        guard let controller, started != nil, frames >= 1, controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        track()
        controller.startPictureInPicture()
    }

    private func pixelBuffer(_ width: Int, _ height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                             kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
            pool = made
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func run(_ script: String) {
        tab?.webView?.evaluateJavaScript("(() => { const p = window.__sillPip; if (!p) return; const v = p.v; \(script) })()", completion: nil)
    }

    /// AVKit's float shows our layer by reference (a layer host in its
    /// panel) at the layer's own size, unscaled: left alone, a big video
    /// shows cropped and a small one sits in a corner. Our layer stays where
    /// the video is on the page, so the flight out starts there and the
    /// flight back lands there; the picture in the panel is scaled to the
    /// panel, every frame the panel is on screen, the flights included.
    private func track() {
        // Opening: fitted in the same pass of the run loop that makes the
        // panel, before Core Animation draws it, so its first frame is right.
        if opening == nil {
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.fit() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            opening = observer
        }
        fit()
    }

    /// Open: only a change of the float's size needs anything done.
    private func settle() {
        if let opening { CFRunLoopObserverInvalidate(opening); self.opening = nil }
        guard let panel, resized == nil else { return }
        resized = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fit() }
        }
        fit()
    }

    /// Where the float shows: where it was last left (macOS keeps it
    /// there too), else the bottom right of the screen, as macOS puts it.
    private static func spot(aspect: CGFloat, near window: NSWindow) -> NSRect {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "PictureInPictureFrame") {
            let frame = NSRectFromString(saved)
            if frame.width > 40, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
                return NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: (frame.width / aspect).rounded())
            }
        }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let width: CGFloat = 362, height = (width / aspect).rounded()
        return NSRect(x: screen.maxX - width - 20, y: screen.minY + 20, width: width, height: height)
    }

    private func remember() {
        guard landed, let panel, panel.frame.width > 40 else { return }
        let frame = NSStringFromRect(panel.frame)
        if UserDefaults.standard.string(forKey: "PictureInPictureFrame") != frame {
            UserDefaults.standard.set(frame, forKey: "PictureInPictureFrame")
        }
    }

    private func fit() {
        remember()
        guard let layer, let (host, size) = floatHost(), size.width > 1, size.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Shown one to one in the panel: the layer is the panel's size...
        if layer.bounds.size != size { layer.frame = CGRect(origin: .zero, size: size) }
        // AVKit's video layer in the float works out its picture's scale and
        // place for a layer the float's size, but stays at a size of its own
        // (1600 × 900): the picture lands off to the side. It is put right.
        for video in host.sublayers ?? [] where String(describing: type(of: video)).contains("VideoContainer") {
            let bounds = CGRect(origin: .zero, size: size), middle = CGPoint(x: size.width / 2, y: size.height / 2)
            if video.bounds != bounds { video.bounds = bounds }
            if video.position != middle || video.anchorPoint != CGPoint(x: 0.5, y: 0.5) {
                video.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                video.position = middle
            }
        }
        CATransaction.commit()
    }

    /// The layer host showing our video in AVKit's panel, and the panel's size.
    private func floatHost() -> (CALayer, CGSize)? {
        if let host, let panel, panel.isVisible, let size = panel.contentView?.bounds.size { return (host, size) }
        host = nil
        panel = nil
        func find(_ layer: CALayer, _ depth: Int) -> CALayer? {
            if String(describing: type(of: layer)) == "CALayerHost" { return layer }
            guard depth < 8 else { return nil }
            for sub in layer.sublayers ?? [] { if let found = find(sub, depth + 1) { return found } }
            return nil
        }
        for window in NSApp.windows where window.isVisible && window.className.contains("PIPPanel") {
            guard let root = window.contentView?.layer, let found = find(root, 0) else { continue }
            host = found
            panel = window
            return (found, window.contentView?.bounds.size ?? window.frame.size)
        }
        return nil
    }

    private func untrack() {
        if let opening { CFRunLoopObserverInvalidate(opening); self.opening = nil }
        if let resized { NotificationCenter.default.removeObserver(resized); self.resized = nil }
        host = nil
        panel = nil
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { track() }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { fit() }
    }

    // MARK: AVKit's window

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            finish(true)
            landed = true
            fit()
            // A moment for AVKit to settle its layout, then hands off.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settle() }
        }
    }


    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated { end() }
    }

    /// The return button: the tab comes back to the front, and the float
    /// flies back into its video.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            remember()
            returning = true
            landed = false
            holder?.removeFromSuperview()
            if let tab { tab.host?.bringBack(tab) }
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard controller === self.controller else { return }
            // Closed with its ✕ rather than put back: the video stops, as in Safari.
            if !returning { run("v.pause();") }
            end()
        }
    }

    // MARK: its buttons, on the video in the page

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated {
            paused = !playing
            if let timebase { CMTimebaseSetRate(timebase, rate: playing ? 1 : 0) }
            controller.invalidatePlaybackState()
            run(playing ? "v.play();" : "v.pause();")
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            // A video of known length shows its progress; a live one, none.
            duration > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
                : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { paused }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        MainActor.assumeIsolated {
            fit()
            // Frames no bigger than the float shows them: less to copy.
            let width = max(320, min(1920, Int(newRenderSize.width)))
            run("p.max = \(width);")
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            let seconds = interval.seconds
            if let timebase {
                let to = max(0, CMTimebaseGetTime(timebase).seconds + seconds)
                CMTimebaseSetTime(timebase, time: CMTime(seconds: to, preferredTimescale: 600))
            }
            run("v.currentTime = Math.max(0, v.currentTime + \(seconds));")
            controller.invalidatePlaybackState()
            completionHandler()
        }
    }
}

