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
        controller.add(router, contentWorld: world, name: "sill")
        return controller
    }()

    /// Private windows share one cookie jar for as long as Sill runs, and it is never written down.
    static let privateStore = WKWebsiteDataStore.nonPersistent()

    /// Safari's own version, so sites serve WebKit what they serve Safari.
    static let applicationName: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    static func configuration(private isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = isPrivate ? privateStore : .default()
        configuration.applicationNameForUserAgent = applicationName
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // Pages out of sight keep running, with WebKit's timer throttling.
        configuration.preferences.inactiveSchedulingPolicy = .throttle
        return configuration
    }
}

/// The web view, knowing which tab it belongs to.
final class SillWebView: WKWebView {
    weak var tab: Tab?

    /// "New Window" reads "New Tab" here: that's what it does.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items {
            item.title = item.title.replacingOccurrences(of: "New Window", with: "New Tab")
            if item.identifier?.rawValue == "WKMenuItemIdentifierDownloadLinkedFile" { item.title = "Download Linked File" }
        }
        super.willOpenMenu(menu, with: event)
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
      const hover = (href) => { if (href !== hovered) { hovered = href; post({ t: 'hover', href }); } };
      document.addEventListener('mouseover', (e) => {
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

/// Site icons, by host: in memory, on disk in Caches, fetched once.
@MainActor
final class Favicons {
    static let shared = Favicons()
    private var memory: [String: NSImage] = [:]
    private var misses: Set<String> = []
    private var inflight: [String: [(NSImage?) -> Void]] = [:]
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

    func cached(for page: URL?) -> NSImage? {
        guard let key = key(page) else { return nil }
        if let image = memory[key] { return image }
        if misses.contains(key) { return nil }
        if let data = try? Data(contentsOf: file(key)), let image = Self.image(from: data) {
            memory[key] = image
            return image
        }
        misses.insert(key)
        return nil
    }

    func fetch(page: URL, icon: URL, done: @escaping (NSImage?) -> Void) {
        guard let key = key(page) else { return done(nil) }
        if inflight[key] != nil { inflight[key]?.append(done); return }
        inflight[key] = [done]
        var request = URLRequest(url: icon)
        request.cachePolicy = .returnCacheDataElseLoad
        session.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                var image: NSImage?
                if let data, (response as? HTTPURLResponse)?.statusCode ?? 200 < 400, let made = Self.image(from: data) {
                    image = made
                    self.memory[key] = made
                    self.misses.remove(key)
                    try? data.write(to: self.file(key), options: .atomic)
                }
                let waiting = self.inflight.removeValue(forKey: key) ?? []
                waiting.forEach { $0(image ?? self.memory[key]) }
            }
        }.resume()
    }

    private static func image(from data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.size.width >= 8 else { return nil }
        return image
    }
}


// MARK: - Picture in Picture

/// Leaving a tab that is playing a video takes the video with you, floating,
/// as Safari does; coming back puts it back in the page.
@MainActor
enum PictureInPicture {
    private static let enter = """
    (() => {
      const v = [...document.querySelectorAll('video')].find(v => !v.paused && !v.ended && v.readyState > 2
        && v.getBoundingClientRect().width > 120 && !v.disablePictureInPicture);
      if (!v || document.pictureInPictureElement || v.webkitPresentationMode === 'picture-in-picture') return false;
      if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
        v.webkitSetPresentationMode('picture-in-picture'); v.dataset.sillPip = '1'; return true;
      }
      return false;
    })()
    """
    private static let exit = """
    (() => {
      const v = document.querySelector('video[data-sill-pip]');
      if (!v) return false;
      delete v.dataset.sillPip;
      if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
      return true;
    })()
    """

    static func leave(_ tab: Tab) {
        guard let webView = tab.webView else { return }
        webView.evaluateJavaScript(enter, in: nil, in: .page) { _ in }
    }

    static func `return`(to tab: Tab) {
        tab.webView?.evaluateJavaScript(exit, in: nil, in: .page) { _ in }
    }
}
