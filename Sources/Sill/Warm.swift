import AppKit
import WebKit

/// claude.ai kept loaded out of sight, so any link to it opens at once.
///
/// claude.ai is a single-page app (TanStack Router): a page that is already
/// running only has to change route, which it does from the standard history
/// events, with no reload. A new tab for any claude.ai address takes the
/// ready page and moves it to that address; another is made a little later
/// for the next link. One for the whole app, never for private windows, and
/// given back when memory runs short.
@MainActor
final class WarmSite: NSObject, WKNavigationDelegate {
    static let shared = WarmSite()

    /// Your recent chats: a page with no text box. The unseen page never opens
    /// a chat or a new chat, so it can't touch a draft you're typing elsewhere
    /// (claude.ai shares drafts between its pages).
    private let home = URL(string: "https://claude.ai/recents")!
    private var view: SillWebView?
    private var ready = false
    private var loadedAt = Date.distantPast
    private var pendingWarm: DispatchWorkItem?
    /// Times in a row the page has waited for the one in front to load.
    private var putOff = 0
    /// A page older than this may be out of date: it is loaded again rather than shown.
    private let freshFor: TimeInterval = 45 * 60

    static func handles(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https" || url.scheme == "http" else { return false }
        return Domains.bare(url.host()) == "claude.ai"
    }

    private var wanted: Bool {
        Preferences.shared.keepsClaudeReady && History.shared.knows(host: "claude.ai")
    }

    /// Makes the page `after` seconds from now, unless one is ready or coming.
    func warm(after delay: TimeInterval = 3) {
        pendingWarm?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.make() }
        }
        pendingWarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func make() {
        guard wanted else { return drop() }
        if let view, ready, Date().timeIntervalSince(loadedAt) < freshFor, Self.usable(view.url) { return }
        // Not while the page you're looking at is still coming in (at launch,
        // the restored tab): an unseen claude.ai loading beside it would
        // share its network and processor. For a few seconds at most.
        if putOff < 8, NSApp.windows.contains(where: { window in
            guard window.isVisible, let browser = window.windowController as? BrowserWindowController else { return false }
            return browser.selected?.isLoading == true
        }) {
            putOff += 1
            return warm(after: 1)
        }
        putOff = 0
        let page = view ?? SillWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                       configuration: Web.configuration(private: false))
        page.navigationDelegate = self
        view = page
        ready = false
        Shield.shared.whenReady { [weak self, weak page] in
            guard let self, let page, self.view === page else { return }
            page.load(URLRequest(url: self.home))
        }
    }

    func drop() {
        pendingWarm?.cancel()
        view?.stopLoading()
        view = nil
        ready = false
    }

    /// The ready page, moved to `url`, for a new tab to take as its own; nil
    /// when there isn't one (still loading, signed out, out of date).
    func claim(_ url: URL) -> SillWebView? {
        guard Self.handles(url), let view, ready, Self.usable(view.url) else { return nil }
        guard Date().timeIntervalSince(loadedAt) < freshFor else {
            warm(after: 0)
            return nil
        }
        self.view = nil
        ready = false
        view.navigationDelegate = nil
        Self.route(view, to: url)
        warm(after: 8)
        return view
    }

    /// Signed in and on the app itself, not a sign-in or error page.
    private static func usable(_ url: URL?) -> Bool {
        guard handles(url), let path = url?.path.lowercased() else { return false }
        return !path.contains("login") && !path.contains("logout") && !path.contains("oauth")
    }

    /// The app's own router follows history: the address is replaced (a new
    /// tab has nothing to go back to) and a popstate makes it show the page.
    /// If the page won't run the script it is loaded the ordinary way.
    private static func route(_ view: SillWebView, to url: URL) {
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query { target += "?" + query }
        if let fragment = url.fragment { target += "#" + fragment }
        let current = view.url.map { $0.path + ($0.query.map { "?" + $0 } ?? "") + ($0.fragment.map { "#" + $0 } ?? "") }
        guard current != target else { return }
        let script = """
        const s = history.state || {};
        const key = Math.random().toString(36).slice(2, 7);
        history.replaceState({ ...s, key, __TSR_key: key }, '', target);
        dispatchEvent(new PopStateEvent('popstate', { state: history.state }));
        return location.pathname + location.search + location.hash;
        """
        view.callAsyncJavaScript(script, arguments: ["target": target], in: nil, in: .page) { [weak view] result in
            if case .failure = result { view?.load(URLRequest(url: url)) }
        }
    }

    // MARK: WKNavigationDelegate (only while the page waits, unseen)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === view else { return }
        ready = Self.usable(webView.url)
        loadedAt = Date()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === view { ready = false }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === view { ready = false }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === view else { return }
        drop()
        warm(after: 30)
    }

    /// Nothing unseen opens windows or downloads.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }
}
