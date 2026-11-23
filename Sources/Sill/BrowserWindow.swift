import AppKit
import Combine
import SwiftUI
import WebKit

/// The window's content, flipped, top-down: the glass ground, the bar, the page.
final class StageView: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The bar and its glass, in one view whose top corners can be rounded
/// without clipping the page below (see BrowserWindowController.applyLooks).
final class TopClipView: NSView {
    override var isFlipped: Bool { true }
}

/// Where the page goes. The window's own colour shows here while a page has
/// yet to draw (see SillWebView.holdForFirstFrame), rather than white in a
/// dark window; drawn by the layer, so it follows light and dark itself.
final class PageHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let isPrivate: Bool
    /// A small window a page opened at a size of its own ("Sign in with…").
    let isPopup: Bool
    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?

    let strip = TabStripView()
    private lazy var bar = TopBar(strip: strip)
    private let stage = StageView()
    private let pageHost = PageHostView()
    /// Two tabs side by side, if one was split (the tab menu's Split Left/Right).
    private(set) var split: SplitPair?
    private var neighbourWarming: DispatchWorkItem?
    private lazy var splitView: PageSplitView = {
        let view = PageSplitView()
        view.onResize = { [weak self] fraction in self?.split?.fraction = fraction }
        return view
    }()
    private lazy var chooser: SplitChooser = {
        let view = SplitChooser()
        view.onPick = { [weak self] tab in self?.fillSplit(with: tab) }
        view.onCancel = { [weak self] in self?.unsplit() }
        return view
    }()
    private let top = TopClipView()
    /// Made the first time they're used, not at the window's first layout.
    private var madePalette: Palette?
    private var madeFindBar: FindBar?
    private var palette: Palette {
        if let madePalette { return madePalette }
        let made = Palette(browser: self)
        madePalette = made
        return made
    }
    private var findBar: FindBar {
        if let madeFindBar { return madeFindBar }
        let made = FindBar(browser: self)
        madeFindBar = made
        return made
    }
    private var paletteOpen: Bool { madePalette?.isOpen ?? false }
    private let status = StatusPill()
    private lazy var peek: Peek = { let peek = Peek(); stage.addSubview(peek); return peek }()
    /// The card over a tab the pointer rests on (TabPreview.swift).
    private lazy var preview = TabPreview()
    private var previewWait: DispatchWorkItem?
    private var previewLeave: DispatchWorkItem?
    private var previewRefresh: Timer?
    private var madePeek = false
    private var hoveredLink: URL?
    private var peekWatch: Any?
    /// The bar's ground: the desktop behind the window, blended by the
    /// window server as Finder's sidebar is (cheap, and steady while the page
    /// redraws), under a wash you set in Settings.
    /// behind the window, under a neutral wash so it stays calm. Larger than
    /// the window so its rim never shows; the page covers it below the bar.
    private let ground = NSVisualEffectView()
    private let wash = NSView()
    /// Made the first time there is something to say: a window is opened,
    /// resized and laid out many times for each note it shows.
    private var madeToast: Toast?
    private var downloadsPopover: NSPopover?
    /// Recently closed in this window, newest last, for ⇧⌘T.
    private var closed: [(url: URL, title: String, index: Int, state: Any?)] = []
    var onChange: (() -> Void)?
    private var napTimer: Timer?
    private var watchingPrefs: AnyCancellable?
    /// The tab whose video Sill sent to picture in picture, to bring back when it's shown again.
    private weak var pictured: Tab?
    /// A web view made while ⌘T is open, so Return doesn't wait for one to
    /// be built before the page can start loading.
    private var spare: SillWebView?
    /// The page whose video is still on its way out to Picture in Picture.
    private weak var leaving: WKWebView?
    private var expected = Set<String>()
    private var connectAheadTimer: Timer?
    private var connectedAhead: [String: Date] = [:]
    /// What the spare is already loading, guessed from the palette's top hit.
    private var prerendered: URL?
    private var prerenderTimer: Timer?

    init(isPrivate: Bool, popup: Bool = false) {
        self.isPrivate = isPrivate
        self.isPopup = popup
        let window = BrowserNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 420, height: 300)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // See-through: the bar's glass shows the desktop behind the window.
        // Opaque unless rounder corners are asked for (Settings › Appearance):
        // a see-through window is composited whole on every frame.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        // No traffic lights: ⌘W, ⇧⌘W, ⌘M and full screen stay in the menus.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        super.init(window: window)
        window.delegate = self

        strip.browser = self
        stage.wantsLayer = true
        // Rounder than the system's window corners; the shadow of a
        // see-through window follows what it draws, so it follows these.
        stage.layer?.cornerCurve = .continuous
        window.contentView = stage
        ground.material = .sidebar
        ground.blendingMode = .behindWindow
        ground.state = .followsWindowActiveState
        top.wantsLayer = true
        top.addSubview(ground)
        wash.wantsLayer = true
        top.addSubview(wash)
        top.addSubview(bar)
        stage.addSubview(top)
        stage.addSubview(pageHost)
        stage.addSubview(status)
        watchForPeek()
        stage.onLayout = { [weak self] in self?.stageLaidOut() }

        bar.back.target = self
        bar.back.action = #selector(goBack(_:))
        bar.forward.target = self
        bar.forward.action = #selector(goForward(_:))
        bar.downloads.target = self
        bar.downloads.action = #selector(showDownloads(_:))
        bar.add.target = self
        bar.add.action = #selector(newTab(_:))
        bar.allTabs.target = self
        bar.allTabs.action = #selector(showAllTabs(_:))
        updateNavigation()
        applyLooks()
        // Settings apply as they change, to every window.
        watchingPrefs = Preferences.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyLooks() }
        }

        window.center()
        // Tabs left alone for a while give their memory back; they reload from
        // their address when shown. Not one playing sound or using the camera.
        napTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.napIdleTabs() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Looks

    private func applyLooks() {
        let prefs = Preferences.shared
        if !isPrivate { window?.appearance = prefs.theme.appearance }
        let amount = CGFloat(prefs.glassWash)
        wash.effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(amount).cgColor
        }
        ground.isHidden = !prefs.glassBar
        wash.isHidden = !prefs.glassBar
        // Rounder corners need a see-through window, clipped to them; the
        // system's own corners cost nothing. Only the corners are clipped:
        // the bar's top two and the page's bottom two. A rounded mask over
        // the whole window, page and all, made every frame of a scrolling
        // page or a video go through an extra offscreen pass.
        let round = prefs.roundCorners
        let radius = round ? prefs.cornerRadius : 0
        window?.isOpaque = !round
        window?.backgroundColor = round ? .clear : .windowBackgroundColor
        // Its own background follows the radius without clipping anything.
        stage.layer?.cornerRadius = radius
        stage.layer?.masksToBounds = false
        stage.layer?.backgroundColor = round && !prefs.glassBar ? NSColor.windowBackgroundColor.cgColor : nil
        Self.clip(top, radius: radius, corners: .top)
        Self.clip(pageHost, radius: radius, corners: .bottom)
        window?.invalidateShadow()
        strip.prefsChanged()
    }

    private enum Edge { case top, bottom }

    /// Rounds and clips two of `view`'s corners, or none at radius 0. A
    /// layer's y runs down the screen when AppKit has flipped it (a flipped
    /// view's own layer is), and then its min-Y corners are the top ones.
    private static func clip(_ view: NSView, radius: CGFloat, corners edge: Edge) {
        guard let layer = view.layer else { return }
        // The view's own orientation: a layer asked before the window has
        // drawn answers the opposite way, and the corners came out upside down.
        let down = view.isFlipped
        let upper: CACornerMask = down ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        let lower: CACornerMask = down ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.cornerCurve = .continuous
        layer.cornerRadius = radius
        layer.maskedCorners = edge == .top ? upper : lower
        layer.masksToBounds = radius > 0
    }

    // MARK: - Bar

    @objc func showDownloads(_ sender: Any?) {
        if downloadsPopover?.isShown == true { downloadsPopover?.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        // Measured before it shows: a popover that shrinks after appearing
        // shrinks from the top, and lands far below its button.
        let host = NSHostingController(rootView: DownloadsView())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        downloadsPopover = popover
        // Progress is read only while the list is open. The popover says when
        // it closes; the view inside isn't told until it is thrown away.
        Downloads.shared.watch(true)
        var closed: NSObjectProtocol?
        closed = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let closed { NotificationCenter.default.removeObserver(closed) }
                closed = nil
                Downloads.shared.watch(false)
                if self?.downloadsPopover === popover { self?.downloadsPopover = nil }
            }
        }
        popover.show(relativeTo: bar.downloadsRect, of: bar, preferredEdge: .maxY)
    }

    @objc func showAllTabs(_ sender: Any?) {
        showPalette(.tabs)
    }

    private func updateNavigation() {
        bar.back.isEnabled = selected?.canGoBack ?? false
        bar.forward.isEnabled = selected?.canGoForward ?? false
    }

    // MARK: - Layout

    var topInset: CGFloat { TopBar.height }

    private func stageLaidOut() {
        top.frame = NSRect(x: 0, y: 0, width: stage.bounds.width, height: TopBar.height)
        bar.frame = top.bounds
        // The page starts below the bar: nothing goes behind the glass.
        pageHost.frame = NSRect(x: 0, y: topInset, width: stage.bounds.width, height: max(0, stage.bounds.height - topInset))
        // Only as tall as the bar plus a margin the page covers: its rim stays
        // hidden under the page, and no glass is drawn where none is seen.
        ground.frame = NSRect(x: 0, y: 0, width: stage.bounds.width, height: TopBar.height)
        wash.frame = ground.frame
        madePalette?.stageResized(stage)
        if let findBar = madeFindBar, findBar.isOpen { findBar.place(in: stage, top: topInset) }
        status.place(in: stage)
        if let toast = madeToast, !toast.isHidden { toast.place(in: stage) }
    }

    func windowDidResize(_ notification: Notification) {
        hidePreview(animated: false)
        stage.needsLayout = true
    }
    func windowDidEnterFullScreen(_ notification: Notification) { stage.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { stage.needsLayout = true }

    // MARK: - Tabs

    func restore(_ states: [SessionTab], selectedIndex: Int) {
        tabs = states.compactMap { state in
            guard let url = URL(string: state.url) else { return nil }
            let tab = Tab(url: url, title: state.title, isPrivate: isPrivate)
            tab.host = self
            return tab
        }
        strip.sync(animated: false)
        if tabs.indices.contains(selectedIndex) { select(tabs[selectedIndex]) } else if let first = tabs.first { select(first) }
    }

    @discardableResult
    func addTab(url: URL?, configuration: WKWebViewConfiguration? = nil, at index: Int? = nil,
                select shouldSelect: Bool = true, opener: Tab? = nil, typed: Bool = false, state: Any? = nil) -> Tab {
        let tab = Tab(url: nil, isPrivate: isPrivate)
        tab.host = self
        tab.opener = opener
        tabs.insert(tab, at: min(index ?? tabs.count, tabs.count))
        if let configuration {
            tab.materialize(with: configuration)
        } else if let url, state == nil, !isPrivate, let view = WarmSite.shared.claim(url) {
            // claude.ai, already running out of sight: it only changes route.
            tab.adopt(view, loaded: true, showing: url)
        } else if let url {
            tab.load(url, typed: typed)
            tab.restore(state)
            if !shouldSelect {
                tab.materialize()
            } else if let view = spare {
                // Return on the site the palette was already loading: the page
                // is there, mid-load or done, and becomes the tab as it is.
                let ready = prerendered.map { Self.samePage($0, url) } ?? false
                spare = nil
                prerendered = nil
                tab.adopt(view, loaded: ready)
            }
        }
        if shouldSelect { select(tab, animated: true) } else { strip.sync(animated: true) }
        changed()
        return tab
    }

    func select(_ tab: Tab, animated: Bool = false) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if paletteOpen && selected !== tab { palette.close(animated: false) }
        madeFindBar?.close()
        let previous = selected
        hidePreview(animated: false)
        // The page being left keeps its place in the window, under the new
        // one, until its video has floated off into Picture in Picture: a
        // page taken out of the window first would have it cancelled. Only
        // a page playing something is asked; any other leaves at once.
        var keep: WKWebView?
        let sideBySide = split?.contains(previous) == true && split?.contains(tab) == true
        if previous !== tab, let previous, let old = previous.webView, Preferences.shared.autoPictureInPicture,
           !sideBySide, previous.playingVideo || Self.isPlayingAudio(old) {
            keep = old
            PictureInPicture.leave(previous) { [weak self, weak old, weak previous] floated in
                guard let self else { return }
                if self.leaving === old { self.leaving = nil }
                if floated, let previous {
                    // Back on it before the video landed: it comes straight back.
                    if previous === self.selected { PictureInPicture.return(to: previous) } else { self.pictured = previous }
                }
                guard let old, old !== self.selected?.webView else { return }
                old.removeFromSuperview()
            }
        }
        selected = tab
        tab.lastShown = Date()
        let webView = tab.materialize()
        placePages(keep: keep)
        tab.reloadIfCrashed()
        // Back from picture in picture: WebKit puts a video back in its page
        // only once that page is in the window, so after it is.
        if tab === pictured {
            pictured = nil
            PictureInPicture.return(to: tab)
        }
        // Clicks, ⌘1–9 and ⌃Tab only move the selection; a tab added or
        // closed changes the row.
        if strip.matches(tabs) { strip.select(tab) } else { strip.sync(animated: animated) }
        strip.markPaired(split?.contains(tab) == true ? split?.other(than: tab) : nil)
        warmNeighbours(of: tab)
        window?.title = tab.displayTitle
        updateNavigation()
        status.show(nil)
        hoveredLink = nil
        endPeek()
        if !paletteOpen { window?.makeFirstResponder(webView) }
        changed()
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        hidePreview(animated: false)
        if let url = tab.webView?.url ?? tab.url, !isPrivate {
            closed.append((url, tab.displayTitle, index, tab.interactionState))
            if closed.count > 30 { closed.removeFirst() }
        }
        tabs.remove(at: index)
        // A split loses one side: the page left over has the window to itself.
        if let split, split.contains(tab) { self.split = nil; strip.markPaired(nil) }
        // Its sound and video go with it, floating or not: nothing keeps
        // playing from a tab that's gone.
        if pictured === tab { pictured = nil }
        Self.silence(tab)
        Web.releaseIdleProcesses()
        if tabs.isEmpty {
            selected = nil
            window?.close()
            return
        }
        if selected === tab {
            // Back to the tab that opened it if it's still alongside; else the one that slid into its place.
            if let opener = tab.opener, tabs.contains(where: { $0 === opener }), index == tabs.count || tabs[index].opener !== tab.opener {
                select(opener, animated: true)
            } else {
                select(tabs[min(index, tabs.count - 1)], animated: true)
            }
        } else {
            strip.sync(animated: true)
        }
        changed()
    }

    /// A tab that loads only when first shown, at the end of the row.
    func appendSleeping(_ url: URL) {
        let tab = Tab(url: url, isPrivate: isPrivate)
        tab.host = self
        tabs.append(tab)
        strip.sync(animated: false)
        if selected == nil { select(tab) }
        changed()
    }

    func move(_ tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(index, tabs.count))
        changed()
    }

    func navigate(to url: URL, newTab: Bool, typed: Bool) {
        if newTab || selected == nil {
            addTab(url: url, typed: typed)
        } else {
            selected?.load(url, typed: typed)
            if let webView = selected?.webView { window?.makeFirstResponder(webView) }
        }
    }

    private func changed() { onChange?() }

    // MARK: - Palette

    func showPalette(_ mode: Palette.Mode) {
        hidePreview(animated: false)
        if paletteOpen && palette.mode == mode && mode == .newTab { palette.close(); return }
        status.show(nil)
        endPeek()
        palette.open(mode, in: stage)
        if mode == .newTab, spare == nil {
            // On the next turn, so the palette is on screen first.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.spare == nil, self.window?.isVisible == true else { return }
                self.spare = SillWebView(frame: self.pageBounds, configuration: Web.configuration(private: self.isPrivate))
                // Starts its web process now, not at Return: no page is loaded.
                self.spare?.evaluateJavaScript("")
                self.expect(Preferences.shared.engine.search(""))
            }
        } else {
            expect(Preferences.shared.engine.search(""))
        }
    }

    /// Opens a connection to a site the palette is likely to send a page to
    /// (the search engine, or a site you've been to that the field is
    /// finishing), so the lookup and handshake are done by the time Return
    /// is pressed. Once per site for each time the palette is open.
    func expect(_ url: URL?) {
        guard let url, url.scheme == "https", let host = url.host() else { return }
        let site = url.port.map { "\(host):\($0)" } ?? host
        guard let view = spare ?? selected?.webView, expected.insert(site).inserted else { return }
        let connect = NSSelectorFromString("_preconnectToServer:")
        guard view.responds(to: connect), let root = URL(string: "https://\(site)/") else { return }
        view.perform(connect, with: root)
    }

    /// While ⌘T is open, its top hit, when it's a site you've been to, starts
    /// loading out of sight in the spare view: Return then shows a page that
    /// is already there. A short pause first, so passing letters don't load.
    func prerenderSoon(_ url: URL?) {
        prerenderTimer?.invalidate()
        guard let url, paletteOpen, palette.mode == .newTab, !isPrivate, !WarmSite.handles(url) || !Preferences.shared.keepsClaudeReady,
              let host = url.host(), History.shared.knows(host: host) else { return }
        if let prerendered, Self.samePage(prerendered, url) { return }
        prerenderTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.paletteOpen else { return }
                let view = self.spare ?? SillWebView(frame: self.pageBounds, configuration: Web.configuration(private: self.isPrivate))
                self.spare = view
                self.prerendered = url
                view.stopLoading()
                Shield.shared.whenReady { [weak view] in view?.load(URLRequest(url: url)) }
            }
        }
    }

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            Domains.bare(url.host()) + (url.path == "/" ? "" : url.path) + (url.query.map { "?" + $0 } ?? "")
        }
        return key(a) == key(b)
    }

    func paletteClosed() {
        expected = []
        if let webView = selected?.webView { window?.makeFirstResponder(webView) }
        // A spare nobody took (the palette was cancelled) gives its page back.
        // Later in the turn, so the Return that closed the palette can claim it.
        // One with no page stays: its process is the started one the next tab
        // would have had, and letting it go leaves that tab to start its own.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.paletteOpen else { return }
            self.prerenderTimer?.invalidate()
            guard self.prerendered != nil else { return }
            self.spare?.stopLoading()
            self.spare = nil
            self.prerendered = nil
        }
    }

    var paletteIsOpen: Bool { paletteOpen }

    // MARK: - Window

    /// WebKit knows whether a page is making sound; it just doesn't say so publicly.
    private static func isPlayingAudio(_ webView: WKWebView) -> Bool {
        let key = "_isPlayingAudio"
        guard webView.responds(to: NSSelectorFromString(key)) else { return true }
        return (webView.value(forKey: key) as? Bool) ?? true
    }

    /// Puts tabs idle for `olderThan` seconds (the setting, unless the Mac is
    /// short of memory and asks sooner) to sleep. Never one on screen (the
    /// one in front, or the other half of its split), one whose video
    /// floats, or one playing sound or using the camera.
    func napIdleTabs(olderThan: TimeInterval? = nil) {
        // Short of memory, the page kept ready for a new tab goes too.
        if olderThan != nil, !paletteOpen { spare = nil }
        guard Preferences.shared.sleepsTabs else { return }
        let after = olderThan ?? TimeInterval(max(5, Preferences.shared.sleepAfterMinutes) * 60)
        let now = Date()
        for tab in tabs where tab !== selected && tab !== pictured {
            // A floating video may be muted, so not "playing audio": it counts anyway.
            guard let webView = tab.webView, webView.window == nil, now.timeIntervalSince(tab.lastShown) > after,
                  webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none,
                  webView.fullscreenState == .notInFullscreen, !Self.isPlayingAudio(webView)
            else { continue }
            tab.sleepUnlessTyping()
        }
    }

    /// Stops everything a page is playing, ends its picture in picture, and
    /// unloads it, for a tab or window being closed.
    static func silence(_ tab: Tab) {
        guard let view = tab.webView else { return }
        let stop = "document.querySelectorAll('video, audio').forEach(m => { try { m.pause(); } catch (_) {} });"
            + " if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});"
        view.evaluateJavaScript(stop, in: nil, in: .page) { _ in }
        view.pauseAllMediaPlayback { }
        view.closeAllMediaPresentations { }
        view.removeFromSuperview()
        // Unloaded a moment later, once the pause has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak view] in
            view?.stopLoading()
            view?.loadHTMLString("", baseURL: nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        for tab in tabs { Self.silence(tab) }
        napTimer?.invalidate()
        spare = nil
        if let peekWatch { NSEvent.removeMonitor(peekWatch) }
        peekWatch = nil
        endPeek()
        for tab in tabs { tab.webView?.removeFromSuperview() }
        Web.releaseIdleProcesses()
        AppDelegate.shared.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) { AppDelegate.shared.lastBrowser = self }
    func windowDidResignKey(_ notification: Notification) { endPeek(); hidePreview(animated: false) }

    // MARK: - Context menu for a tab

    func menu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ handler: @escaping () -> Void, enabled: Bool = true) {
            let item = ClosureMenuItem(title: title, handler: handler)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("New Tab") { [weak self] in self?.showPalette(.newTab) }
        menu.addItem(.separator())
        add("Reload") { tab.reload() }
        add("Duplicate") { [weak self] in
            guard let self, let url = tab.webView?.url ?? tab.url,
                  let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.addTab(url: url, at: index + 1)
        }
        add("Copy Link", { if let url = tab.webView?.url ?? tab.url { Pasteboard.copy(url) } }, enabled: tab.url != nil)
        menu.addItem(.separator())
        if split?.contains(tab) == true {
            add("Separate Split View") { [weak self] in self?.unsplit() }
        } else {
            add("Split Left") { [weak self] in self?.split(tab, onLeft: true) }
            add("Split Right") { [weak self] in self?.split(tab, onLeft: false) }
        }
        // Off for the one site it broke, rather than everywhere.
        if Preferences.shared.blocksAds, let host = (tab.webView?.url ?? tab.url)?.host(), !host.isEmpty {
            let paused = Shield.shared.isPaused(on: host)
            let item = ClosureMenuItem(title: "Block Ads on \(Domains.bare(host))") { [weak tab] in
                Shield.shared.pause(host, !paused) { tab?.reload() }
            }
            item.state = paused ? .off : .on
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("Close Tab") { [weak self] in self?.close(tab) }
        add("Close Other Tabs", { [weak self] in
            guard let self else { return }
            for other in self.tabs where other !== tab { self.close(other) }
        }, enabled: tabs.count > 1)
        add("Close Tabs to the Right", { [weak self] in
            guard let self, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            for other in self.tabs[(index + 1)...] { self.close(other) }
        }, enabled: tabs.last !== tab)
        return menu
    }

    // MARK: - Status, toast

    func toast(_ text: String, action: (String, () -> Void)? = nil) {
        let toast = madeToast ?? {
            let made = Toast()
            // Where it has always been: over the page and the status, under the rest.
            stage.addSubview(made, positioned: .above, relativeTo: status)
            madeToast = made
            return made
        }()
        toast.show(text, action: action, in: stage)
    }

    // MARK: - Menu actions

    @objc func newTab(_ sender: Any?) { showPalette(.newTab) }
    @objc func openLocation(_ sender: Any?) { showPalette(selected == nil ? .newTab : .address) }

    @objc func closeTab(_ sender: Any?) {
        if paletteOpen { palette.close(); return }
        if let selected { close(selected) } else { window?.close() }
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        guard let last = closed.popLast() else { return }
        // With its back and forward history, as it was.
        addTab(url: last.url, at: min(last.index, tabs.count), state: last.state)
    }

    @objc func goBack(_ sender: Any?) { selected?.goBack() }
    @objc func goForward(_ sender: Any?) { selected?.goForward() }
    @objc func reloadPage(_ sender: Any?) { selected?.reload() }
    @objc func reloadFromOrigin(_ sender: Any?) { selected?.reload(fromOrigin: true) }
    @objc func stopLoading(_ sender: Any?) { selected?.stop() }

    @objc func nextTab(_ sender: Any?) { step(1) }
    @objc func previousTab(_ sender: Any?) { step(-1) }
    private func step(_ delta: Int) {
        guard let selected, let index = tabs.firstIndex(where: { $0 === selected }), tabs.count > 1 else { return }
        select(tabs[(index + delta + tabs.count) % tabs.count])
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        let n = sender.tag
        select(n >= 9 ? tabs[tabs.count - 1] : tabs[min(n - 1, tabs.count - 1)])
    }

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.1) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 1 / 1.1) }
    @objc func actualSize(_ sender: Any?) { selected?.webView?.pageZoom = 1 }
    private func zoom(by factor: CGFloat) {
        guard let webView = selected?.webView else { return }
        webView.pageZoom = max(0.3, min(3, (webView.pageZoom * factor * 100).rounded() / 100))
    }

    @objc func copyPageLink(_ sender: Any?) {
        guard let url = selected?.webView?.url ?? selected?.url else { return }
        Pasteboard.copy(url)
        toast("Link copied")
    }

    @objc func showFind(_ sender: Any?) {
        guard selected?.webView != nil else { return }
        findBar.open(in: stage, top: topInset)
    }
    @objc func findNext(_ sender: Any?) { findBar.find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { findBar.find(backwards: true) }

    @objc func showInspector(_ sender: Any?) {
        // Web Inspector is a right-click away (Inspect Element); this opens it directly.
        guard let webView = selected?.webView else { return }
        let selector = NSSelectorFromString("_showWebInspector")
        if let inspector = webView.value(forKey: "_inspector") as? NSObject, inspector.responds(to: NSSelectorFromString("show")) {
            inspector.perform(NSSelectorFromString("show"))
        } else if webView.responds(to: selector) {
            webView.perform(selector)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(goBack(_:)): return selected?.canGoBack ?? false
        case #selector(goForward(_:)): return selected?.canGoForward ?? false
        case #selector(reopenClosedTab(_:)): return !closed.isEmpty
        case #selector(reloadPage(_:)), #selector(reloadFromOrigin(_:)), #selector(copyPageLink(_:)),
             #selector(showFind(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualSize(_:)),
             #selector(showInspector(_:)):
            return selected != nil
        case #selector(stopLoading(_:)): return selected?.isLoading ?? false
        case #selector(findNext(_:)), #selector(findPrevious(_:)): return madeFindBar?.hasQuery ?? false
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return tabs.count > 1
        case #selector(selectTabByNumber(_:)): return item.tag <= tabs.count || item.tag == 9
        default: return true
        }
    }
}

// MARK: - TabHost

extension BrowserWindowController: TabHost {
    func tabChanged(_ tab: Tab, _ what: Tab.Change) {
        switch what {
        case .icon, .loading:
            strip.refresh(tab)
        case .title:
            // Not a session save: titles are read when it's written, and a
            // page ticking its title would put the save off forever.
            retitle(tab)
        case .url:
            retitle(tab)
            changed()
        case .navigation:
            if tab === selected { updateNavigation() }
        case .scroll:
            break
        }
    }

    /// A new title or address reaches the strip and the window at once,
    /// twice in any half second: a load's address and then its title. A page
    /// that keeps changing them is shown its latest when the half second is up,
    /// not redrawn for each.
    private func retitle(_ tab: Tab) {
        // A load's own changes (redirects, then the title) are never held.
        if tab.isLoading { return showTitle(of: tab, at: CACurrentMediaTime()) }
        guard !tab.retitling else { return }
        let now = CACurrentMediaTime()
        let wait = (tab.retitled.0 + 0.5) - now
        guard wait > 0 else { return showTitle(of: tab, at: now) }
        tab.retitling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak tab] in
            guard let tab else { return }
            tab.retitling = false
            self?.showTitle(of: tab, at: CACurrentMediaTime())
        }
    }

    private func showTitle(of tab: Tab, at now: CFTimeInterval) {
        tab.retitled = (tab.retitled.1, now)
        guard tabs.contains(where: { $0 === tab }) else { return }
        strip.refresh(tab)
        if tab === selected { window?.title = tab.displayTitle }
    }

    func open(from tab: Tab, url: URL?, configuration: WKWebViewConfiguration?, background: Bool) -> Tab {
        // Links open beside the page they came from, after any it opened before.
        var index = (tabs.firstIndex { $0 === tab } ?? tabs.count - 1) + 1
        while index < tabs.count, tabs[index].opener === tab { index += 1 }
        return addTab(url: url, configuration: configuration, at: index, select: !background, opener: tab)
    }

    func openPopup(from tab: Tab, configuration: WKWebViewConfiguration, size: NSSize) -> Tab? {
        let popup = AppDelegate.shared.makeBrowser(isPrivate: isPrivate, popup: true)
        guard let window = popup.window, let parent = self.window else { return nil }
        let content = NSSize(width: max(360, min(size.width, 1000)), height: max(320, min(size.height, 900)) + TopBar.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2)
        window.setFrame(frame, display: false)
        let made = popup.addTab(url: nil, configuration: configuration, opener: tab)
        popup.showWindow(nil)
        return made
    }

    func closeRequested(_ tab: Tab) { close(tab) }

    func bringBack(_ tab: Tab) {
        select(tab, animated: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hovered(_ tab: Tab, link: String?) {
        guard tab === selected, !paletteOpen else { return }
        let url = link.flatMap(URL.init(string:))
        hoveredLink = url
        peekIfAsked()
        connectAhead(to: url, from: tab)
        guard Preferences.shared.showsLinkPreview else { return }
        status.show(url.map { Address.display($0) })
    }

    /// Resting the pointer on a link to another site opens a connection to
    /// it, in the page's own data store, so the lookup and handshake are
    /// under way before the click. A connection only: nothing is requested.
    private func connectAhead(to url: URL?, from tab: Tab) {
        connectAheadTimer?.invalidate()
        guard let url, url.scheme == "https", let host = url.host(), let view = tab.webView else { return }
        let site = url.port.map { "\(host):\($0)" } ?? host
        let here = view.url.flatMap { page in page.host().map { name in page.port.map { "\(name):\($0)" } ?? name } }
        guard site != here || view.url?.scheme != "https",
              connectedAhead[site].map({ Date().timeIntervalSince($0) > 30 }) ?? true
        else { return }
        connectAheadTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                let connect = NSSelectorFromString("_preconnectToServer:")
                guard let self, let view, view.responds(to: connect), let root = URL(string: "https://\(site)/") else { return }
                if self.connectedAhead.count > 64 { self.connectedAhead = [:] }
                self.connectedAhead[site] = Date()
                view.perform(connect, with: root)
            }
        }
    }

    // MARK: - A look at a link

    /// ⌥ going down or up, and anything that ends a look: a click, a key, a scroll.
    private func watchForPeek() {
        guard peekWatch == nil else { return }
        peekWatch = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .flagsChanged { self.peekIfAsked() } else { self.endPeek() }
            return event
        }
    }

    private func peekIfAsked() {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let url = hoveredLink, let tab = selected, let window, window.isKeyWindow, !paletteOpen,
              flags.contains(.option), flags.isDisjoint(with: [.command, .control, .shift]),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              // Not a place on the page it's already on.
              url.absoluteString.split(separator: "#").first != tab.webView?.url?.absoluteString.split(separator: "#").first
        else { return endPeek() }
        let point = stage.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        madePeek = true
        peek.show(url, by: point, in: stage, below: topInset, private: tab.isPrivate)
    }

    private func endPeek() {
        if madePeek { peek.hide() }
    }

    func focused(_ tab: Tab, field: LoginField) {
        guard tab === selected, let webView = tab.webView else { return }
        Autofill.offer(for: field, in: tab, webView: webView, top: topInset)
    }
}

// MARK: - Bits

final class BrowserNSWindow: NSWindow {
    /// Esc anywhere puts the palette or the find bar away.
    override func cancelOperation(_ sender: Any?) {
        (windowController as? BrowserWindowController)?.escape()
    }

    /// The shortcuts worth holding down. The menu bar flashes its title for every repeat and
    /// sleeps the main thread some 50 ms each time to do it, so a held key steps at a third of
    /// the repeat rate with nothing drawn in between. The repeats go straight to the action;
    /// the first press still goes through the menu.
    private static let held: Set<Selector> = [
        #selector(BrowserWindowController.nextTab(_:)), #selector(BrowserWindowController.previousTab(_:)),
        #selector(BrowserWindowController.findNext(_:)), #selector(BrowserWindowController.findPrevious(_:)),
        #selector(BrowserWindowController.zoomIn(_:)), #selector(BrowserWindowController.zoomOut(_:)),
        #selector(BrowserWindowController.goBack(_:)), #selector(BrowserWindowController.goForward(_:)),
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A page in front takes Control-Tab for itself and the menu never hears of it.
        if event.type == .keyDown, event.keyCode == 48,
           let controller = windowController as? BrowserWindowController {
            switch event.modifierFlags.intersection([.command, .shift, .control, .option]) {
            case .control: controller.nextTab(nil); return true
            case [.control, .shift]: controller.previousTab(nil); return true
            default: break
            }
        }
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown, event.isARepeat,
              let controller = windowController as? BrowserWindowController,
              let key = event.characters(byApplyingModifiers: .command), !key.isEmpty,
              let item = Self.item(for: key, event.modifierFlags.intersection([.command, .shift, .control, .option]),
                                   in: NSApp.mainMenu) else { return false }
        if controller.validateMenuItem(item), let action = item.action {
            NSApp.sendAction(action, to: controller, from: item)
        }
        return true
    }

    private static func item(for key: String, _ modifiers: NSEvent.ModifierFlags, in menu: NSMenu?) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if let found = Self.item(for: key, modifiers, in: item.submenu) { return found }
            guard let action = item.action, held.contains(action) else { continue }
            // "+" is the key "=" with Shift, and is reached without it too.
            let plus = item.keyEquivalent == "+"
            if (plus ? "=" : item.keyEquivalent) == key,
               item.keyEquivalentModifierMask == modifiers || (plus && item.keyEquivalentModifierMask.union(.shift) == modifiers) {
                return item
            }
        }
        return nil
    }
}

extension BrowserWindowController {
    func escape() {
        if paletteOpen { palette.close() } else if madeFindBar?.isOpen == true { madeFindBar?.close() }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

enum Pasteboard {
    static func copy(_ url: URL) {
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
        board.setString(url.absoluteString, forType: .string)
    }
}


// MARK: - Split view

extension BrowserWindowController {
    /// The page area: the one tab in front, or both halves of its split.
    fileprivate func placePages(keep: WKWebView?) {
        guard let selected else { return }
        if let keep { leaving = keep }
        if let split, split.contains(selected) {
            // As for one page below: the pair comes back under the page being left.
            let shown = selected.webView as? SillWebView
            let under = keep == nil && leaving?.superview !== pageHost
                && shown?.shownBefore == true && splitView.superview !== pageHost
                && pageHost.subviews.contains { $0 is WKWebView }
            if !under {
                for view in pageHost.subviews where view !== keep && view !== splitView { view.removeFromSuperview() }
            }
            if splitView.superview !== pageHost {
                splitView.frame = pageHost.bounds
                splitView.autoresizingMask = [.width, .height]
                pageHost.addSubview(splitView, positioned: under ? .below : .above, relativeTo: nil)
            }
            if under, let shown {
                for case let old as SillWebView in pageHost.subviews { old.outgoing = true }
                shown.afterNextFrame { [weak self, weak shown] in
                    guard let self, shown != nil, self.split?.contains(self.selected) == true,
                          self.splitView.superview === self.pageHost else { return }
                    for view in self.pageHost.subviews where view !== self.splitView && view !== self.leaving { view.removeFromSuperview() }
                }
            }
            for (pane, tab) in [(splitView.leftPane, split.left), (splitView.rightPane, split.right)] {
                if let tab {
                    let view = tab.materialize()
                    pane.show(view)
                    view.shownBefore = true
                } else {
                    chooser.offer(tabs.filter { !split.contains($0) })
                    pane.show(chooser)
                }
            }
            splitView.layoutSubtreeIfNeeded()
            splitView.apply(fraction: split.fraction)
        } else {
            let webView = selected.materialize()
            // A page that has been shown before comes back under the one
            // being left, which goes once the new one has drawn: nothing
            // waits, and the window never shows through between the two.
            let under = keep == nil && leaving?.superview !== pageHost
                && webView.shownBefore && webView.superview !== pageHost
                && !webView.isDescendant(of: splitView)
                && pageHost.subviews.contains { $0 is WKWebView || $0 === splitView }
            if !under {
                for view in pageHost.subviews where view !== keep && view !== webView { view.removeFromSuperview() }
            }
            if webView.superview !== pageHost {
                webView.frame = pageHost.bounds
                webView.autoresizingMask = [.width, .height]
                pageHost.addSubview(webView, positioned: under ? .below : .above, relativeTo: nil)
            }
            webView.shownBefore = true
            webView.outgoing = false
            if under {
                for case let old as SillWebView in pageHost.subviews where old !== webView { old.outgoing = true }
                webView.afterNextFrame { [weak self, weak webView] in
                    guard let self, let webView, self.selected?.webView === webView,
                          webView.superview === self.pageHost else { return }
                    for view in self.pageHost.subviews where view !== webView && view !== self.leaving { view.removeFromSuperview() }
                }
            }
        }
    }

    /// Split Left / Split Right: the tab goes to that side, and the other side
    /// asks which open tab to show there.
    func split(_ tab: Tab, onLeft: Bool) {
        split = onLeft ? SplitPair(left: tab, right: nil) : SplitPair(left: nil, right: tab)
        if selected === tab {
            placePages(keep: nil)
            strip.markPaired(nil)
        } else {
            select(tab)
        }
    }

    fileprivate func fillSplit(with tab: Tab) {
        guard let split else { return }
        if split.left == nil { split.left = tab } else { split.right = tab }
        select(tab)
        placePages(keep: nil)
        strip.markPaired(split.other(than: tab))
    }

    @objc func unsplit() {
        guard split != nil else { return }
        split = nil
        strip.markPaired(nil)
        placePages(keep: nil)
        if let webView = selected?.webView { window?.makeFirstResponder(webView) }
    }

    var windowNumber: Int { window?.windowNumber ?? 0 }

    var pageBounds: NSRect {
        pageHost.bounds.width > 0 ? NSRect(origin: .zero, size: pageHost.bounds.size) : NSRect(x: 0, y: 0, width: 1280, height: 800)
    }

    /// Starts a sleeping or never-shown tab loading in the background.
    // MARK: - Tab previews

    /// The pointer came onto a tab: a card after a short rest, or at once if
    /// one is already up for another tab.
    func tabHovered(_ tab: Tab, in item: NSView) {
        previewLeave?.cancel()
        previewWait?.cancel()
        guard Preferences.shared.showsTabPreviews, !paletteOpen,
              window?.isKeyWindow == true, NSEvent.pressedMouseButtons == 0 else { return hidePreview() }
        if preview.isShowing { return showPreview(tab, under: item) }
        // The picture is taken now, so it's there when the card comes.
        freshenPicture(of: tab)
        let work = DispatchWorkItem { [weak self, weak item, weak tab] in
            guard let self, let item, let tab, item.window != nil, NSEvent.pressedMouseButtons == 0 else { return }
            self.showPreview(tab, under: item)
        }
        previewWait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// Off a tab: the card waits a moment for the next tab along the row.
    func tabUnhovered(_ tab: Tab) {
        previewWait?.cancel()
        guard preview.isShowing else { return }
        let work = DispatchWorkItem { [weak self] in self?.hidePreview() }
        previewLeave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func showPreview(_ tab: Tab, under item: NSView) {
        if preview.superview !== stage || stage.subviews.last !== preview { stage.addSubview(preview) }
        preview.fill(tab, pageSize: pageBounds.size)
        let tabFrame = stage.convert(item.bounds, from: item)
        let size = preview.cardSize
        let x = max(8, min(tabFrame.midX - size.width / 2, stage.bounds.width - 8 - size.width))
        preview.present(at: NSPoint(x: x, y: topInset + 4))
        freshenPicture(of: tab)
        // Kept up to date only while something on it moves: a video, a page
        // still coming in. A still page is pictured once.
        if previewRefresh == nil {
            previewRefresh = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let tab = self.preview.tab else { return }
                    if tab.playingVideo || tab.picture == nil { self.freshenPicture(of: tab, within: 0.9) }
                }
            }
            previewRefresh?.tolerance = 0.25
        }
    }

    /// A new picture of a running page, unless it has one from the last
    /// `within` seconds or is still loading (it would be half drawn).
    private func freshenPicture(of tab: Tab, within: CFTimeInterval = 2) {
        guard tab.webView != nil, !tab.isLoading,
              tab.picture == nil || CACurrentMediaTime() - tab.pictureTakenAt > within else { return }
        tab.capturePicture { [weak self, weak tab] image in
            guard let self, let tab, let image, self.preview.tab === tab else { return }
            tab.sleepingPicture = nil
            self.preview.show(image)
            self.preview.retitle()
        }
    }

    func hidePreview(animated: Bool = true) {
        previewWait?.cancel()
        previewLeave?.cancel()
        previewRefresh?.invalidate()
        previewRefresh = nil
        preview.dismiss(animated: animated)
        // Pictures of running pages are taken again in a moment when wanted;
        // none is held between looks. Only a sleeping tab's small one stays.
        for tab in tabs where tab.picture != nil { tab.picture = nil }
    }

    func warm(_ tab: Tab) {
        guard tab.webView == nil, tab.url != nil, tabs.contains(where: { $0 === tab }) else { return }
        tab.materialize()
    }

    /// The tabs either side of the one in front, a moment after it changes:
    /// the next ⌃Tab, or a click next door, finds its page already there.
    fileprivate func warmNeighbours(of tab: Tab) {
        neighbourWarming?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab === self.selected, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            for i in [index - 1, index + 1] where self.tabs.indices.contains(i) { self.warm(self.tabs[i]) }
        }
        neighbourWarming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// A click into the other half of a split makes that page the one in
    /// front: the address, back and forward and page commands follow it.
    func paneFocused(_ tab: Tab) {
        guard let split, split.contains(tab), selected !== tab, tabs.contains(where: { $0 === tab }) else { return }
        selected = tab
        tab.lastShown = Date()
        strip.select(tab)
        strip.markPaired(split.other(than: tab))
        window?.title = tab.displayTitle
        updateNavigation()
        changed()
    }
}
