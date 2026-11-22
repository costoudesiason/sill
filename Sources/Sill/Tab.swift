import AppKit
import UniformTypeIdentifiers
import WebKit

/// What a tab needs from the window it lives in.
@MainActor
protocol TabHost: AnyObject {
    var window: NSWindow? { get }
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
    /// The tab this one was opened from, for placing and for going back to it.
    weak var opener: Tab?

    private(set) var webView: SillWebView?
    private(set) var url: URL?
    private(set) var title: String
    private(set) var favicon: NSImage?
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Whether the page is scrolled away from its top.
    private(set) var isScrolled = false
    /// Whether a video is playing in the page, as its script last said.
    private(set) var playingVideo = false
    var lastShown = Date()

    private var pending: URL?
    private var watching: [NSKeyValueObservation] = []
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
        let view = SillWebView(frame: .zero, configuration: configuration ?? Web.configuration(private: isPrivate))
        // A configuration WebKit hands over for a new window is a copy made
        // inside WebKit: picture in picture is allowed again to be sure.
        PictureInPicture.allow(view.configuration.preferences)
        view.tab = self
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.allowsLinkPreview = true
        view.isInspectable = true
        webView = view
        watch(view)
        if let pending, configuration == nil {
            self.pending = nil
            Shield.shared.whenReady { [weak self, weak view] in
                guard let view, self?.webView === view else { return }
                view.load(URLRequest(url: pending))
            }
        }
        return view
    }

    private func watch(_ view: SillWebView) {
        watching = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = view.title, !title.isEmpty || view.url != nil else { return }
                    self.title = title
                    if !self.isPrivate, let url = view.url { History.shared.retitle(url, title) }
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
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
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

    /// Lets the page go to save memory; it comes back from its address when shown.
    func sleep() {
        guard let webView, !webView.isLoading else { return }
        pending = webView.url ?? url
        playingVideo = false
        watching = []
        webView.removeFromSuperview()
        self.webView = nil
    }

    // MARK: - going places

    func load(_ url: URL, typed: Bool = false) {
        typedNavigation = typed
        self.url = url
        if let webView {
            Shield.shared.whenReady { [weak self, weak webView] in
                guard let webView, self?.webView === webView else { return }
                webView.load(URLRequest(url: url))
            }
        } else {
            pending = url
        }
        host?.tabChanged(self, .url)
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload(fromOrigin: Bool = false) {
        guard let webView else { return }
        if webView.url == nil, let url { webView.load(URLRequest(url: url)) }
        else if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
    }
    func stop() { webView?.stopLoading() }

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
            guard let self, let image, self.webView?.url?.host() == page.host() else { return }
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
        decisionHandler(response.canShowMIMEType ? .allow : .download)
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
        guard let url = webView.url else { return }
        if !isPrivate { History.shared.record(url, title: webView.title, typed: typedNavigation) }
        typedNavigation = false
        if favicon == nil || Favicons.shared.cached(for: url) == nil {
            favicon = Favicons.shared.cached(for: url)
            host?.tabChanged(self, .icon)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let error = error as NSError
        // Cancelled, or a download taking over, or a plug-in: not a failure to show.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code)) { return }
        guard let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url else { return }
        let html = ErrorPage.html(title: "Can’t open this page", detail: error.localizedDescription, url: failed)
        webView.loadSimulatedRequest(URLRequest(url: failed), responseHTML: html)
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

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
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
        guard let tab = host?.open(from: self, url: nil, configuration: configuration, background: background) else { return nil }
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.closeRequested(self)
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
        Prompts.alert(message, from: frame, in: host?.window) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        Prompts.confirm(message, from: frame, in: host?.window, completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        Prompts.input(prompt, defaultText: defaultText, from: frame, in: host?.window, completionHandler)
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
