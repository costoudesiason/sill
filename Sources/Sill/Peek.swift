import AppKit
import WebKit

/// A look at where a link goes: hold ⌥ while pointing at it and the page
/// shows in a small card by the pointer, live, until either lets go.
///
/// It's asked for, never automatic: loading a page fetches it, and a link
/// can be "sign out". Nothing exists until the first look, and nothing is
/// kept after it: the web view is made for the card and dropped with it,
/// and each look has a data store of its own, so the page is seen signed
/// out: a page can't use a look to send a request as you, and what the
/// looked-at page stores goes with the card.
final class Peek: NSView, WKNavigationDelegate, WKUIDelegate {
    static let size = NSSize(width: 420, height: 306)
    private static let foot: CGFloat = 44

    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    /// Under the page and the foot: the card reads the same over any page.
    private let ground = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private let rule = NSBox()
    private var page: SillWebView?
    private var titleWatch: NSKeyValueObservation?
    private var waiting: DispatchWorkItem?
    private(set) var link: URL?
    private var isPrivate = false

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        isHidden = true
        glass.cornerRadius = 16
        glass.contentView = content
        glass.frame = bounds
        addSubview(glass)
        content.frame = bounds
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        ground.material = .popover
        ground.blendingMode = .withinWindow
        ground.state = .active
        ground.frame = bounds
        content.addSubview(ground)
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 22
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addressLabel.font = .systemFont(ofSize: 11)
        addressLabel.textColor = .secondaryLabelColor
        addressLabel.lineBreakMode = .byTruncatingMiddle
        rule.boxType = .separator
        let top = Self.size.height - Self.foot
        rule.frame = NSRect(x: 0, y: top, width: Self.size.width, height: 1)
        titleLabel.frame = NSRect(x: 14, y: top + 7, width: Self.size.width - 28, height: 16)
        addressLabel.frame = NSRect(x: 14, y: top + 23, width: Self.size.width - 28, height: 14)
        [rule, titleLabel, addressLabel].forEach(content.addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pointer goes through it: the link under it stays the link.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `url` by `point` (in `stage`), after a beat so brushing past
    /// a link with ⌥ down loads nothing.
    func show(_ url: URL, by point: NSPoint, in stage: NSView, below top: CGFloat, private isPrivate: Bool) {
        guard url != link else { return }
        hide()
        link = url
        let work = DispatchWorkItem { [weak self] in self?.open(url, by: point, in: stage, below: top, private: isPrivate) }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func open(_ url: URL, by point: NSPoint, in stage: NSView, below top: CGFloat, private isPrivate: Bool) {
        self.isPrivate = isPrivate
        let pageFrame = NSRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height - Self.foot)
        // A look keeps nothing: in memory only, like a private window. (Made
        // straight, not by changing the shared configuration: that once made
        // every tab opened after a look private, and signed out.)
        let view = SillWebView(frame: pageFrame, private: true)
        // A look makes no sound.
        view.audioMuted = true
        // Half size: a desktop-width page in a card.
        view.pageZoom = 0.5
        view.holdForFirstFrame()
        content.addSubview(view, positioned: .below, relativeTo: rule)
        page = view
        titleLabel.stringValue = url.host() ?? ""
        addressLabel.stringValue = Address.display(url)
        titleWatch = view.observe(\.title) { [weak self] view, _ in
            MainActor.assumeIsolated {
                if let title = view.title, !title.isEmpty { self?.titleLabel.stringValue = title }
            }
        }
        Shield.shared.whenReady { [weak view] in view?.load(URLRequest(url: url)) }

        // Below and right of the pointer; the other side where it won't fit.
        let gap: CGFloat = 18, edge: CGFloat = 10
        var origin = NSPoint(x: point.x + gap, y: point.y + gap)
        if origin.x + Self.size.width > stage.bounds.width - edge { origin.x = point.x - gap - Self.size.width }
        if origin.y + Self.size.height > stage.bounds.height - edge { origin.y = point.y - gap - Self.size.height }
        origin.x = max(edge, min(origin.x, stage.bounds.width - edge - Self.size.width))
        origin.y = max(top + edge, min(origin.y, stage.bounds.height - edge - Self.size.height))
        Motion.still {
            frame = NSRect(origin: origin, size: Self.size)
            alphaValue = 0
            isHidden = false
        }
        Motion.animate(Motion.quick) { animator().alphaValue = 1 }
    }

    func hide() {
        waiting?.cancel()
        waiting = nil
        guard link != nil else { return }
        link = nil
        titleWatch = nil
        guard let page else { return }
        self.page = nil
        page.stopLoading()
        // Closed once faded: closed first, its card went blank as it faded.
        Motion.animate(0.1, { animator().alphaValue = 0 }, completion: { [weak self] in
            page.closePage()
            page.removeFromSuperview()
            if self?.link == nil { self?.isHidden = true }
        })
    }

    // MARK: Only pages

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        if action.shouldPerformDownload { return .cancel }
        if action.targetFrame?.isMainFrame != false, !["http", "https"].contains(scheme) { return .cancel }
        // Plain HTTP out on the internet is asked about first, in a tab: a look doesn't ask.
        if action.targetFrame?.isMainFrame != false, scheme == "http", let site = action.request.url?.host(),
           SitePermissions.asksBeforeHTTP(site),
           !SitePermissions.shared.continuesOverHTTP(to: site, private: isPrivate) { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .cancel
    }

    /// A look is never asked for the camera or the microphone.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        if events & SillWebView.firstFrame != 0 { (webView as? SillWebView)?.showFirstFrame() }
    }
}
