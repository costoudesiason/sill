import AppKit
import UniformTypeIdentifiers
import WebKit

/// What a tab needs from the window it lives in.
@MainActor
protocol TabHost: AnyObject {
    var window: NSWindow? { get }
    /// The page area's size: pages loaded out of sight are laid out at it,
    /// so they're ready to show as they are, and readable by agents.
    var pageBounds: NSRect { get }
    func tabChanged(_ tab: Tab, _ what: Tab.Change)
    func open(from tab: Tab, url: URL?, configuration: WKWebViewConfiguration?, background: Bool) -> Tab
    func openPopup(from tab: Tab, configuration: WKWebViewConfiguration, size: NSSize) -> Tab?
    func closeRequested(_ tab: Tab)
    /// To the front, with its window: its video is coming back from picture in picture.
    func bringBack(_ tab: Tab)
    func hovered(_ tab: Tab, link: String?)
    func focused(_ tab: Tab, field: LoginField)
}

/// One page and its history. Its web view is made the first time it is
/// shown, so restored tabs cost nothing until they're clicked.
@MainActor
final class Tab: NSObject {
    enum Change { case title, url, loading, icon, navigation, scroll }

    let id = UUID()
    let isPrivate: Bool
    weak var host: TabHost?
    /// When the window last showed this tab's title or address, the last two
    /// times, and whether a showing is waiting its turn.
    var retitled: (CFTimeInterval, CFTimeInterval) = (0, 0)
    var retitling = false
    /// The page as it was last seen, for the preview card over its tab
    /// (TabPreview.swift): a picture while the page runs, let go when the
    /// card goes; squeezed small while the tab sleeps.
    var picture: CGImage?
    var pictureTakenAt: CFTimeInterval = 0
    var sleepingPicture: Data?
    /// The tab this one was opened from, for placing and for going back to it.
    weak var opener: Tab?

    private(set) var webView: SillWebView?
    private(set) var url: URL?
    private(set) var title: String
    private(set) var favicon: NSImage?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Whether the page is scrolled away from its top.
    private(set) var isScrolled = false
    /// Whether a video is playing in the page, as its script last said.
    private(set) var playingVideo = false
    var lastShown = Date()
    /// Opened by an agent through Sill's agent socket.
    var openedByAgent = false

    private var pending: URL?
    /// The page's back/forward list and place in it, kept while the tab
    /// sleeps (or after it closed), so it comes back as it was and from
    /// WebKit's caches rather than as a fresh load of its address.
    private var savedState: Any?
    private var watching: [NSKeyValueObservation] = []
    /// When its page's process last died, for telling a crash loop from a one-off.
    private var crashes: [Date] = []
    /// Its process died while it was out of sight: it reloads when shown.
    private var needsReload = false
    /// Sill ended this page's process itself (it had stopped answering):
    /// not a crash to count, and what to load in its place, if not the same page.
    private var endedHungProcess = false
    private var afterHungProcess: URL?
    /// A reload (nil address) or address asked for and not yet begun by the
    /// page: if the page turns out to be hung, it is what to do after.
    private var asked: (url: URL?, at: Date)?
    /// The navigation that put Sill's own "can't open" page up, and whether
    /// that page is what's showing: it is not a visit to remember.
    private var errorNavigation: WKNavigation?
    private var showingError = false
    /// Dialogs its page asked for while behind another tab, kept until it is seen.
    private var heldPrompts: [(_ shown: Bool) -> Void] = []
    /// The title last given to history, for which page: a page that keeps
    /// setting the same title doesn't touch history again.
    private var lastRetitled: (url: URL, title: String)?
    /// Typed or picked in the palette: counts for more in history.
    private var typedNavigation = false

    init(url: URL?, title: String = "", isPrivate: Bool) {
        self.url = url
        self.title = title
        self.isPrivate = isPrivate
        self.pending = url
        super.init()
        favicon = Favicons.shared.cached(for: url)
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = url?.host() { return Domains.bare(host) }
        return url == nil ? "New Tab" : Address.display(url)
    }

    var isBlank: Bool { url == nil && webView?.url == nil }

    // MARK: - the web view

    @discardableResult
    func materialize(with configuration: WKWebViewConfiguration? = nil) -> SillWebView {
        if let webView { return webView }
        let view = SillWebView(frame: host?.pageBounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800),
                               configuration: configuration ?? Web.configuration(private: isPrivate))
        adopt(view, popup: configuration != nil)
        return view
    }

    /// Takes `view` as this tab's page, made just now or ahead of time (the
    /// window keeps one ready while ⌘T is open), and loads what's waiting.
    /// `popup`: WebKit made its configuration for a window a page opened,
    /// and loads it itself.
    func adopt(_ view: SillWebView, popup: Bool = false, loaded: Bool = false, showing shown: URL? = nil) {
        guard webView == nil else { return }
        // A configuration WebKit hands over for a new window is a copy made
        // inside WebKit: picture in picture is allowed again to be sure.
        PictureInPicture.allow(view.configuration.preferences)
        Web.backspaceStays(view.configuration.preferences)
        view.tab = self
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.allowsLinkPreview = true
        view.isInspectable = true
        webView = view
        watch(view)
        // Already loading (or loaded) this very page: keep it, take its place.
        if loaded {
            pending = nil
            savedState = nil
            if let url = shown ?? view.url { self.url = url }
            if let title = view.title, !title.isEmpty { self.title = title }
            if !isPrivate, let url = shown ?? view.url { History.shared.record(url, title: shown == nil ? view.title : nil, typed: true) }
            favicon = Favicons.shared.cached(for: view.url ?? url)
            isLoading = view.isLoading
            host?.tabChanged(self, .url)
            host?.tabChanged(self, .title)
            return
        }
        // Unseen until it draws, when there's a page coming; a popup's view
        // is already drawing what its opener put there.
        if !popup, savedState != nil || pending != nil { view.holdForFirstFrame() }
        if !popup, let state = savedState {
            savedState = nil
            pending = nil
            Shield.shared.whenReady { [weak self, weak view] in
                guard let view, self?.webView === view else { return }
                view.interactionState = state
            }
        } else if let pending, !popup {
            self.pending = nil
            Shield.shared.whenReady { [weak self, weak view] in
                guard let view, self?.webView === view else { return }
                view.load(URLRequest(url: pending))
            }
        }
    }

    private func watch(_ view: SillWebView) {
        watching = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = view.title, !title.isEmpty || view.url != nil else { return }
                    self.title = title
                    if !self.isPrivate, !self.showingError, let url = view.url, self.lastRetitled?.url != url || self.lastRetitled?.title != title {
                        self.lastRetitled = (url, title)
                        History.shared.retitle(url, title)
                    }
                    self.host?.tabChanged(self, .title)
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = view.url else { return }
                    let hostChanged = url.host() != self.url?.host()
                    self.url = url
                    if hostChanged, let icon = Favicons.shared.cached(for: url) { self.favicon = icon; self.host?.tabChanged(self, .icon) }
                    self.host?.tabChanged(self, .url)
                }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLoading = view.isLoading
                    self.host?.tabChanged(self, .loading)
                }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.canGoBack = view.canGoBack
                    self.host?.tabChanged(self, .navigation)
                }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.canGoForward = view.canGoForward
                    self.host?.tabChanged(self, .navigation)
                }
            },
        ]
    }

    /// Lets the page go to save memory; it comes back, with its history and
    /// place, when shown.
    func sleep() {
        guard let webView, !webView.isLoading else { return }
        // Waking reloads it anyway: a crash noted before sleeping mustn't reload it twice.
        needsReload = false
        dropHeldPrompts()
        pending = webView.url ?? url
        savedState = webView.interactionState
        playingVideo = false
        watching = []
        webView.removeFromSuperview()
        self.webView = nil
        picture = nil
        // Asleep to give memory back: its process isn't kept waiting either.
        Web.releaseIdleProcesses()
    }

    /// Sleeps, unless something has been typed into the page and not sent:
    /// a sleeping page would lose it.
    func sleepUnlessTyping() {
        guard let webView else { return }
        let typing = """
        (function () {
          var e = document.activeElement;
          return !!(e && (e.isContentEditable || ((e.tagName === 'INPUT' || e.tagName === 'TEXTAREA') && e.value)));
        })();
        """
        webView.evaluateJavaScript(typing, in: nil, in: Web.world) { [weak self, weak webView] result in
            // A page that can't be asked (a PDF, say) has nothing typed in it.
            guard let self, let webView, self.webView === webView, (try? result.get()) as? Bool != true else { return }
            // Its preview keeps the page as it was, kept small while it sleeps.
            guard Preferences.shared.showsTabPreviews else { return self.sleep() }
            self.capturePicture { [weak self, weak webView] image in
                guard let self, let webView, self.webView === webView else { return }
                if let image { self.keepWhileAsleep(image) }
                self.sleep()
            }
        }
    }

    /// The history of a tab that was closed, for ⇧⌘T: used the first time it's shown.
    func restore(_ state: Any?) {
        guard webView == nil, let state else { return }
        savedState = state
    }

    var interactionState: Any? { webView?.interactionState }

    // MARK: - going places

    func load(_ url: URL, typed: Bool = false) {
        typedNavigation = typed
        self.url = url
        if let webView, !webView.processIsResponsive {
            endHungProcess(of: webView, thenLoad: url)
        } else if let webView {
            asked = (url, Date())
            Shield.shared.whenReady { [weak self, weak webView] in
                guard let webView, self?.webView === webView else { return }
                webView.load(URLRequest(url: url))
            }
        } else {
            pending = url
            savedState = nil
        }
        host?.tabChanged(self, .url)
    }

    /// Shown again after its process died behind another tab.
    func reloadIfCrashed() {
        guard needsReload else { return }
        needsReload = false
        reload()
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload(fromOrigin: Bool = false) {
        guard let webView else { return }
        if !webView.processIsResponsive { return endHungProcess(of: webView, thenLoad: nil) }
        asked = (nil, Date())
        if webView.url == nil, let url { webView.load(URLRequest(url: url)) }
        else if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
    }
    func stop() { webView?.stopLoading() }

    /// A page stuck in a script answers nothing, a reload or a new address
    /// included: its process is ended, and the page loads in a fresh one.
    private func endHungProcess(of webView: SillWebView, thenLoad url: URL?) {
        endedHungProcess = true
        afterHungProcess = url
        webView.endProcess()
    }

    /// Runs `present` once this tab's page is in a window; at once if it is.
    /// A dialog from a tab behind another waits for that tab rather than
    /// landing on whatever page is in front. `shown` is false if the page
    /// went away first, and the dialog is to be answered unseen.
    func whenShown(_ present: @escaping (_ shown: Bool) -> Void) {
        if (webView as? SillWebView)?.isShown == true { present(true) } else { heldPrompts.append(present) }
    }

    /// The page is in a window (again): what waited for that goes ahead.
    func pageShown() {
        guard !heldPrompts.isEmpty else { return }
        let held = heldPrompts
        heldPrompts = []
        held.forEach { $0(true) }
    }

    /// The page is going away: its waiting dialogs are answered as cancelled.
    func dropHeldPrompts() {
        guard !heldPrompts.isEmpty else { return }
        let held = heldPrompts
        heldPrompts = []
        held.forEach { $0(false) }
    }

    // MARK: - from the page script

    func hovered(link: String?) { host?.hovered(self, link: link) }

    /// A link the middle button opened: a tab of its own, behind unless ⇧.
    func middleClicked(_ url: URL, shift: Bool) {
        _ = host?.open(from: self, url: url, configuration: nil, background: !shift)
    }

    func scrolled(_ value: Bool) {
        guard value != isScrolled else { return }
        isScrolled = value
        host?.tabChanged(self, .scroll)
    }
    func focused(_ field: LoginField) { host?.focused(self, field: field) }
    func mediaChanged(_ playing: Bool) { playingVideo = playing }

    func found(icon: URL) {
        guard let page = webView?.url else { return }
        Favicons.shared.fetch(page: page, icon: icon) { [weak self] image in
            // The icon it already shows: nothing to redraw.
            guard let self, let image, image !== self.favicon, self.webView?.url?.host() == page.host() else { return }
            self.favicon = image
            self.host?.tabChanged(self, .icon)
        }
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if action.shouldPerformDownload { return decisionHandler(.download) }

        let scheme = url.scheme?.lowercased() ?? ""
        let web = ["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme)
        if !web {
            // mailto:, facetime:, zoommtg:… belong to other apps.
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true {
                NSWorkspace.shared.open(url)
            }
            return decisionHandler(.cancel)
        }

        // 0.0.0.0, as dev servers print it, is this Mac: localhost.
        if action.targetFrame?.isMainFrame == true, url.host() == "0.0.0.0",
           var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.host = "localhost"
            if let local = parts.url { webView.load(URLRequest(url: local)) }
            return decisionHandler(.cancel)
        }

        // The middle button never comes this way as a choice of tab (the
        // page script opens it); WebKit reports buttons as a mask, 4 middle.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            return decisionHandler(.cancel)
        }

        // ⌘-click: a tab behind this one. ⇧⌘-click: in front.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command),
           ["http", "https"].contains(scheme) {
            _ = host?.open(from: self, url: url, configuration: nil,
                           background: !action.modifierFlags.contains(.shift))
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"), disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        if response.canShowMIMEType { return decisionHandler(.allow) }
        // A page is never a download: HTML, text or no type at all (a
        // service worker's answer may come without one) is left to WebKit.
        let type = response.response.mimeType?.lowercased() ?? ""
        if type.isEmpty || type.hasPrefix("text/") || type.contains("html") || type.contains("xml") || type.contains("json") {
            return decisionHandler(.allow)
        }
        // Frames inside a page don't save files behind your back; only the
        // page you're looking at downloads what it can't show.
        decisionHandler(response.isForMainFrame ? .download : .cancel)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.track(download, in: host?.window)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.track(download, in: host?.window)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        scrolled(false)
        playingVideo = false
        asked = nil
        // The link the pointer was on went with the old page.
        hovered(link: nil)
        showingError = errorNavigation != nil && navigation === errorNavigation
        errorNavigation = nil
        guard let url = webView.url else { return }
        if !isPrivate, !showingError { History.shared.record(url, title: webView.title, typed: typedNavigation) }
        typedNavigation = false
        if favicon == nil || Favicons.shared.cached(for: url) == nil {
            favicon = Favicons.shared.cached(for: url)
            host?.tabChanged(self, .icon)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame: done is done.
        (webView as? SillWebView)?.showFirstFrame()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        (webView as? SillWebView)?.showFirstFrame()
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        (webView as? SillWebView)?.showFirstFrame()
        showError(error, in: webView)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let error = error as NSError
        asked = nil
        // Cancelled, or a download taking over, or a plug-in: not a failure to show.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code)) { return }
        guard let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url else { return }
        let html = ErrorPage.html(title: "Can’t open this page", detail: error.localizedDescription, url: failed)
        errorNavigation = webView.loadSimulatedRequest(URLRequest(url: failed), responseHTML: html)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest,
              let window = host?.window else { return completionHandler(.performDefaultHandling, nil) }
        Prompts.credentials(for: challenge.protectionSpace, in: window) { credential in
            completionHandler(credential == nil ? .cancelAuthenticationChallenge : .useCredential, credential)
        }
    }

    /// The page's process has stopped answering (a script that never ends).
    /// A reload or address asked of it in the last moments is what found
    /// that out, and would wait for ever: the process is ended for it.
    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        guard let view = webView as? SillWebView, view === self.webView else { return }
        if let asked, Date().timeIntervalSince(asked.at) < 15 {
            self.asked = nil
            return endHungProcess(of: view, thenLoad: asked.url)
        }
        view.processStoppedAnswering()
    }

    /// The page's process died (out of memory, or a crash). Shown, it comes
    /// back at once; behind another tab, when it's next shown. Twice in a
    /// minute, it says so rather than reloading into the same crash forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dropHeldPrompts()
        asked = nil
        if endedHungProcess {
            endedHungProcess = false
            if let next = afterHungProcess { webView.load(URLRequest(url: next)) }
            else if (webView as? SillWebView)?.isShown != true { needsReload = true } else { webView.reload() }
            afterHungProcess = nil
            return
        }
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if crashes.count >= 2, let url = webView.url ?? url {
            crashes = []
            needsReload = false
            let html = ErrorPage.html(title: "This page keeps crashing",
                                      detail: "Its content process stopped twice in a minute, so Sill didn’t reload it again.", url: url)
            errorNavigation = webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
            return
        }
        if (webView as? SillWebView)?.isShown != true { needsReload = true } else { webView.reload() }
    }
}

// MARK: - UI

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A window the page sizes itself ("Sign in with…") opens as a small
        // window over this one; any other new window becomes a tab. Either
        // way the page keeps its opener, so sign-ins hand their answer back.
        let sized = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        if sized, !action.modifierFlags.contains(.command) {
            let size = NSSize(width: windowFeatures.width?.doubleValue ?? 520, height: windowFeatures.height?.doubleValue ?? 640)
            return host?.openPopup(from: self, configuration: configuration, size: size)?.webView
        }
        let background = action.modifierFlags.contains(.command) && !action.modifierFlags.contains(.shift)
        // A claude.ai link opens in the page kept ready for it; the link
        // doesn't need a handle on the new tab.
        if !isPrivate, action.navigationType == .linkActivated, let url = action.request.url,
           WarmSite.handles(url), Preferences.shared.keepsClaudeReady {
            _ = host?.open(from: self, url: url, configuration: nil, background: background)
            return nil
        }
        guard let tab = host?.open(from: self, url: nil, configuration: configuration, background: background) else { return nil }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.closeRequested(self)
    }

    /// The page has drawn something: a view kept unseen so far comes in.
    /// WebKit calls this only on a view that asked (holdForFirstFrame); it is
    /// a navigation-delegate call, answered here because Tab is both delegates.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        if events & SillWebView.firstFrame != 0 { (webView as? SillWebView)?.showFirstFrame() }
    }

    /// The button on macOS's picture in picture window that puts the video
    /// back. WebKit puts it back into its page only once that page is seen,
    /// and the page is a tab behind another: it comes to the front first.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        host?.bringBack(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        whenShown { [weak self] shown in
            guard shown else { return completionHandler() }
            Prompts.alert(message, from: frame, in: self?.host?.window) { completionHandler() }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        whenShown { [weak self] shown in
            guard shown else { return completionHandler(false) }
            Prompts.confirm(message, from: frame, in: self?.host?.window, completionHandler)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        whenShown { [weak self] shown in
            guard shown else { return completionHandler(nil) }
            Prompts.input(prompt, defaultText: defaultText, from: frame, in: self?.host?.window, completionHandler)
        }
    }

    /// A page with something unsaved (it listens for beforeunload) asks
    /// before it is left or reloaded, as it does in Safari.
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runBeforeUnloadConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard (webView as? SillWebView)?.isShown == true else { return completionHandler(true) }
        Prompts.leave(in: host?.window, completionHandler)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = host?.window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }
}

// MARK: - Error page

enum ErrorPage {
    static func html(title: String, detail: String, url: URL) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <meta name="color-scheme" content="light dark">
        <style>
        html,body{height:100%;margin:0}
        body{font:14px -apple-system,system-ui;display:flex;align-items:center;justify-content:center;
             background:Canvas;color:CanvasText;-webkit-user-select:none}
        main{max-width:440px;padding:24px;text-align:left}
        h1{font-size:22px;font-weight:600;margin:0 0 8px;letter-spacing:-.01em}
        p{margin:0 0 6px;color:color-mix(in srgb,CanvasText 60%,transparent);line-height:1.45}
        code{font:12px ui-monospace,Menlo;word-break:break-all}
        button{margin-top:18px;font:13px -apple-system;padding:6px 16px;border-radius:999px;border:0;
               background:color-mix(in srgb,CanvasText 9%,transparent);color:CanvasText}
        button:active{transform:scale(.97)}
        </style></head><body><main>
        <h1>\(escape(title))</h1><p>\(escape(detail))</p><p><code>\(escape(Address.display(url)))</code></p>
        <button onclick="location.reload()">Try Again</button>
        </main></body></html>
        """
    }
}
