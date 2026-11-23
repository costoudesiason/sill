import AppKit
import WebKit

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
    }()

    /// Starts the first web process while the window is still being built,
    /// so the first page doesn't wait for one. The first of a launch is by
    /// far the slowest to start.
    static func warm() {
        let start = NSSelectorFromString("_warmInitialProcess")
        if pool.responds(to: start) { pool.perform(start) }
    }

    /// WebKit keeps the process of a page that has gone (its tab closed or
    /// put to sleep) for the site's next page, for half an hour, with some
    /// of what the page had allocated still in it: tens of megabytes each,
    /// over a hundred for a heavy site. They are let go once tabs have stopped
    /// going for half a minute, not sooner: while tabs are still being closed
    /// and opened the kept processes are what the next pages start in. The
    /// process kept started for the next page is not one of them. A site's
    /// service worker outlives its page by some seconds and only then is its
    /// process kept, hence the second pass.
    static func releaseIdleProcesses() {
        let clear = NSSelectorFromString("_clearWebProcessCache")
        guard pool.responds(to: clear) else { return }
        releases.forEach { $0.cancel() }
        releases = [30, 50].map { delay in
            let work = DispatchWorkItem { pool.perform(clear) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }
    private static var releases: [DispatchWorkItem] = []

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

    static func configuration(private isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = pool
        configuration.userContentController = controller
        configuration.websiteDataStore = isPrivate ? privateStore : .default()
        configuration.applicationNameForUserAgent = applicationName
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // A page opens windows when you click, not on its own.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Pages out of sight are left to WebKit's default, which suspends a
        // page once it is idle and in no window: a tab behind another costs
        // nothing. A page playing sound or video, or still loading, isn't
        // idle, so background audio and picture in picture carry on.
        PictureInPicture.allow(configuration.preferences)
        backspaceStays(configuration.preferences)
        // A page out of sight has its timers held to one tick a second; this
        // lets the gap grow the longer it stays hidden, as Safari does. Each
        // tick that touches the page otherwise wakes the app to draw nothing.
        let grows = NSSelectorFromString("_setHiddenPageDOMTimerThrottlingAutoIncreases:")
        if configuration.preferences.responds(to: grows) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(configuration.preferences.method(for: grows), to: Setter.self)(configuration.preferences, grows, true)
        }
        // WebKit's own wait for a page put back in the window to draw is
        // left on: without it a page that hasn't drawn since it was away
        // showed its empty (black) layer, and a still page might not draw
        // again. The page being left stays on top until then (placePages).
        return configuration
    }
}

/// The web view, knowing which tab it belongs to.
final class SillWebView: WKWebView {
    weak var tab: Tab?

    /// Clicking into one half of a split brings that half's tab to the front.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let tab, let host = tab.host as? BrowserWindowController { host.paneFocused(tab) }
        return became
    }

    /// False once WebKit has found the page's process isn't answering
    /// (a script that never ends).
    var processIsResponsive: Bool {
        let selector = NSSelectorFromString("_webProcessIsResponsive")
        guard responds(to: selector) else { return true }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method(for: selector), to: Getter.self)(self, selector)
    }

    /// Ends the page's process, as a crash would. By its pid: a process
    /// that isn't answering doesn't take WebKit's own request to stop.
    func endProcess() {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        guard responds(to: selector) else { return }
        typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
        let pid = unsafeBitCast(method(for: selector), to: Getter.self)(self, selector)
        if pid > 0 { kill(pid, SIGKILL) }
    }

    /// A page that isn't answering would swallow ⌘W, ⌘T and ⌘R for good:
    /// they go to the menu instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard processIsResponsive else { return false }
        let taken = super.performKeyEquivalent(with: event)
        unanswered = taken ? event : nil
        return taken
    }

    /// The last shortcut handed to the page, which hands it back if it has
    /// no use for it. A page that hangs never does.
    private var unanswered: NSEvent?

    /// WebKit has found the page isn't answering: the shortcut it was just
    /// given (within the few seconds that takes to notice) goes to the menu.
    func processStoppedAnswering() {
        guard let event = unanswered else { return }
        unanswered = nil
        if ProcessInfo.processInfo.systemUptime - event.timestamp < 10, window?.isKeyWindow == true {
            NSApp.mainMenu?.performKeyEquivalent(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { tab?.pageShown() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if window != nil { tab?.pageShown() }
    }

    /// "New Window" reads "New Tab" here: that's what it does.
    /// The page's right-click menu is Sill's glass one: WebKit's items, in
    /// the same order, run as WebKit runs them. Items that open a submenu
    /// (Share, Services, Speech) aren't offered; the native menu doesn't show.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items {
            item.title = item.title.replacingOccurrences(of: "New Window", with: "New Tab")
            if item.identifier?.rawValue == "WKMenuItemIdentifierDownloadLinkedFile" { item.title = "Download Linked File" }
        }
        super.willOpenMenu(menu, with: event)
        guard let window, GlassMenu.isEnabledForPages else { return }
        let kept = menu.items.filter { $0.isSeparatorItem || ($0.submenu == nil && !$0.isHidden && $0.action != nil) }
        let copy = NSMenu()
        for item in kept { menu.removeItem(item); copy.addItem(item) }
        menu.removeAllItems()
        // macOS adds its Services item to any menu left: not to this one.
        menu.allowsContextMenuPlugIns = false
        let entries = GlassMenu.entries(from: copy, symbols: Self.symbols)
        guard !entries.isEmpty else { return }
        let point = event.locationInWindow
        // After WebKit has finished with its own (now empty) menu.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            withExtendedLifetime(copy) {
                GlassMenu(title: nil, entries: entries, searchable: entries.count > 8).show(in: window, at: point, from: nil)
            }
        }
    }

    private static let symbols: [String: String] = [
        "Open Link in New Tab": "plus.square.on.square", "Open Link": "arrow.up.right.square",
        "Download Linked File": "arrow.down.circle", "Copy Link": "link", "Copy": "doc.on.doc",
        "Open Image in New Tab": "photo.on.rectangle", "Save Image As…": "square.and.arrow.down",
        "Copy Image": "photo", "Copy Image Address": "link", "Back": "chevron.backward", "Forward": "chevron.forward",
        "Reload": "arrow.clockwise", "Inspect Element": "hammer", "Look Up": "character.book.closed",
        "Paste": "doc.on.clipboard", "Cut": "scissors", "Select All": "selection.pin.in.out",
        "Search with Google": "magnifyingglass", "Translate": "translate", "Download Image": "arrow.down.circle",
        "Download Video": "arrow.down.circle", "Copy Video Address": "link", "Show Controls": "slider.horizontal.below.rectangle",
        "Enter Full Screen": "arrow.up.left.and.arrow.down.right", "Enter Picture in Picture": "pip.enter",
    ]

    /// The page being left stays over the one coming in until that has drawn;
    /// for that moment it is only a picture, and clicks go to the new page.
    var outgoing = false
    override func hitTest(_ point: NSPoint) -> NSView? { outgoing ? nil : super.hitTest(point) }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        outgoing = false
    }

    /// On screen: in a window and not put aside (see `park`).
    var isShown: Bool { window != nil && !isHidden }

    /// Put aside where it is, hidden, rather than taken out of the window.
    /// WebKit blanks a page that comes back into a window until it has drawn
    /// again, and holds the app still for that drawing; a page that was only
    /// hidden still has its last frame and is simply shown.
    func park() {
        guard !isHidden else { return }
        isHidden = true
        outgoing = false
        // Not resized with the window while it's away; sized when shown.
        autoresizingMask = []
    }

    // MARK: the first frame

    /// A web view that has never drawn is opaque white: a flash of it between
    /// opening a tab and the page arriving, worst in a dark window. So a fresh
    /// view starts unseen, over the window's own colour, and comes in once
    /// WebKit says there is something on it worth seeing.
    private var held = false
    /// Has been in a window before, so it has a page to draw the moment it's back.
    var shownBefore = false

    /// Runs once the view's next frame is in the window, or shortly after
    /// if WebKit never says.
    func afterNextFrame(_ run: @escaping () -> Void) {
        let presented = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard responds(to: presented) else { return run() }
        var done = false
        let once = { if !done { done = true; run() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { once() }
        typealias After = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(method(for: presented), to: After.self)(self, presented) { DispatchQueue.main.async { once() } }
    }
    private var presenting = false

    /// _WKRenderingProgressEventFirstVisuallyNonEmptyLayout, the moment
    /// Safari shows a page that is coming in.
    static let firstFrame: UInt = 1 << 1

    /// WebKit tells of the first frame only through names outside the public
    /// framework, so it's asked whether it knows them first; one that doesn't
    /// shows the view straight away, as before.
    func holdForFirstFrame() {
        let observe = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard responds(to: observe) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: observe), to: Setter.self)(self, observe, Self.firstFrame)
        held = true
        alphaValue = 0
        // A web process that dies before it draws never says so: in after a second regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showFirstFrame() }
    }

    /// In, quickly, once that frame has reached the window: WebKit reports
    /// it a few frames before, and fading in then still shows the white.
    func showFirstFrame() {
        guard held, !presenting else { return }
        presenting = true
        let fadeIn = { [weak self] in
            guard let self, self.held else { return }
            self.held = false
            self.presenting = false
            Motion.animate(0.12) { self.animator().alphaValue = 1 }
        }
        let presented = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard responds(to: presented) else { return fadeIn() }
        var done = false
        let once = { if !done { done = true; fadeIn() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { once() }
        typealias After = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(method(for: presented), to: After.self)(self, presented) { DispatchQueue.main.async { once() } }
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

      // Away from the top, for the toolbar's edge.
      let away = false;
      addEventListener('scroll', () => {
        const now = (document.scrollingElement || document.documentElement).scrollTop > 0;
        if (now !== away) { away = now; post({ t: 'scroll', v: now }); }
      }, { passive: true });

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
    private var misses: Set<String> = []
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
        func put(_ key: String, _ image: NSImage) { lock.withLock { images?[key] = image } }
        func image(_ key: String) -> NSImage? { lock.withLock { images?[key] } }
        func close() { lock.withLock { images = nil } }
    }
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
        DispatchQueue.global(qos: .userInitiated).async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            var found: [(String, NSImage)] = []
            for url in files {
                guard let data = try? Data(contentsOf: url), let (image, _) = Self.decode(data, storing: false) else { continue }
                found.append((url.lastPathComponent, image))
                staged.put(url.lastPathComponent, image)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (key, image) in found where self.memory[key] == nil { self.memory[key] = image }
                    self.preloaded = true
                    staged.close()
                }
            }
        }
    }

    func cached(for page: URL?) -> NSImage? {
        guard let key = key(page) else { return nil }
        if let image = memory[key] { return image }
        if preloaded || misses.contains(key) { return nil }
        if let image = staged.image(key.replacingOccurrences(of: "/", with: "_")) {
            memory[key] = image
            return image
        }
        // Asked before the preload has finished: from disk, this once.
        if let data = try? Data(contentsOf: file(key)), let (image, _) = Self.decode(data) {
            memory[key] = image
            return image
        }
        misses.insert(key)
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
                        self.misses.remove(key)
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

