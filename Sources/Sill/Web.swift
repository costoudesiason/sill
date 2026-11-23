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
    static func configuration(private isPrivate: Bool) -> WKWebViewConfiguration {
        isPrivate ? privateMarker : normalMarker
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

    // Chromium answers for its own processes.
    var processIsResponsive: Bool { true }
    func endProcess() { reload() }
    func processStoppedAnswering() {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pageHidden = !isShown
        if isShown { tab?.pageShown() }
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        pageHidden = !isShown
        if isShown { tab?.pageShown() }
    }
    override func viewDidHide() {
        super.viewDidHide()
        pageHidden = true
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

    /// Put aside where it is, hidden: Chromium stops drawing it.
    func park() {
        guard !isHidden else { return }
        isHidden = true
        outgoing = false
        autoresizingMask = []
    }

    var shownBefore = false
    var laidOutUnseen = false
    private(set) var drawingAhead = false
    func startDrawingAhead() {}
    func cameIntoView() { if isShown { tab?.pageShown() } }
    func afterNextFrame(within limit: TimeInterval = 0.25, _ run: @escaping () -> Void) {
        DispatchQueue.main.async(execute: run)
    }
    var isFullyIn: Bool { true }
    static let firstFrame: UInt = 1 << 1
    func holdForFirstFrame() {}
    func showFirstFrame(laidOut: Bool = true) {}

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
              let body = message.body as? [String: Any],
              let type = body["t"] as? String
        else { return }
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
        case "pipReturn":
            // Back from the floating window: to its tab, its window, to the front.
            tab.host?.bringBack(tab)
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
      const post = (m) => { try { webkit.messageHandlers.sill.postMessage(m); } catch (_) {} };

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
      };
      ['playing', 'pause', 'ended', 'emptied', 'volumechange'].forEach(e => document.addEventListener(e, media, true));
      media();

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
enum PictureInPicture {
    /// Lets pages in `preferences` use picture in picture, as Safari does.
    /// Always on: the setting only decides whether Sill floats a video by
    /// itself, and pages' own PiP buttons work either way.
    static func allow(_ preferences: WKPreferences) {
        let set = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, true)
    }

    /// The largest video playing, into picture in picture. Answers "in",
    /// "none" (nothing playing) or "refused".
    private static let enter = """
    (function () {
      var videos = document.querySelectorAll('video'), best = null, area = 0;
      for (var i = 0; i < videos.length; i++) {
        var v = videos[i];
        if (v.webkitPresentationMode === 'picture-in-picture') return 'in';
        if (v.paused || v.ended || v.readyState < 2 || v.muted || v.volume === 0) continue;
        var box = v.getBoundingClientRect();
        // A real video, not a muted preview or a background loop.
        if (box.width < 200 || box.height < 112) continue;
        if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
      }
      if (!best) return 'none';
      if (!best.webkitSupportsPresentationMode || !best.webkitSupportsPresentationMode('picture-in-picture')) return 'refused';
      try { best.webkitSetPresentationMode('picture-in-picture'); return 'in'; } catch (e) { return 'refused'; }
    })();
    """

    /// Back into the page, whatever is floating from it.
    private static let exit = """
    (function () {
      var videos = document.querySelectorAll('video'), out = false;
      for (var i = 0; i < videos.length; i++) {
        if (videos[i].webkitPresentationMode === 'picture-in-picture') {
          try { videos[i].webkitSetPresentationMode('inline'); out = true; } catch (e) {}
        }
      }
      return out ? 'out' : 'none';
    })();
    """

    /// `done(true)` runs once the video has floated (after the window
    /// animation), `done(false)` straight away when nothing did.
    static func leave(_ tab: Tab, done: @escaping (Bool) -> Void) {
        // A video in full screen is already where it wants to be.
        guard let webView = tab.webView, webView.fullscreenState == .notInFullscreen else { return done(false) }
        webView.evaluateJavaScript(enter, in: nil, in: Web.world) { result in
            if (try? result.get()) as? String == "in" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done(true) }
            } else {
                done(false)
            }
        }
    }

    static func `return`(to tab: Tab) {
        tab.webView?.evaluateJavaScript(exit, in: nil, in: Web.world) { _ in }
    }
}
