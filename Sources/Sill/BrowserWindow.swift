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
    /// Pairs of tabs side by side (the tab menu's Split Left/Right): as
    /// many as you make, each tab in one at most.
    private(set) var splits: [SplitPair] = []
    /// A split being made, waiting for its second tab.
    private var pendingSplit: SplitPair?
    /// The split showing: the one being made, else the one the tab in
    /// front belongs to.
    var split: SplitPair? { pendingSplit ?? splits.first { $0.contains(selected) } }
    /// The split `tab` is one half of, if any.
    func split(of tab: Tab?) -> SplitPair? { splits.first { $0.contains(tab) } }
    /// Every whole split, for the row's capsules.
    private func showPairs() {
        strip.showPairs(splits.compactMap { pair in pair.left.flatMap { l in pair.right.map { (l, $0) } } })
    }
    /// Takes `tab` out of whatever split it's in, which then ends.
    private func dissolveSplit(of tab: Tab?) {
        if let pending = pendingSplit, pending.contains(tab) { pendingSplit = nil }
        splits.removeAll { $0.contains(tab) }
    }
    private var neighbourWarming: DispatchWorkItem?
    private lazy var splitView: PageSplitView = {
        let view = PageSplitView()
        view.onResize = { [weak self] fraction in
            self?.split?.fraction = fraction
            self?.placePrompts()
        }
        view.onSettle = { [weak self] in self?.changed() }
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
    private(set) var fullScreenPage: Tab?
    private var enteredForPage = false
    private let status = StatusPill()
    private lazy var peek: Peek = { let peek = Peek(); stage.addSubview(peek); return peek }()
    /// The card over a tab the pointer rests on (TabPreview.swift).
    private lazy var preview = TabPreview()
    /// The thin line between the bar and the page while the page loads.
    private let loadingLine = LoadingLine()
    /// Below the bar when there's no page (no tab, or a new one with nothing
    /// in it yet): the bar's own material, so the empty window is glass,
    /// showing the desktop, not a black page.
    private lazy var emptyGlass: NSVisualEffectView = {
        let glass = NSVisualEffectView()
        glass.material = .sidebar
        glass.blendingMode = .behindWindow
        glass.state = .followsWindowActiveState
        glass.isHidden = true
        stage.addSubview(glass, positioned: .below, relativeTo: pageHost)
        return glass
    }()

    /// Shows the glass under the bar when nothing is there to cover it.
    private func showEmptyGlass() {
        let empty = selected == nil || selected?.isBlank == true
        if empty { emptyGlass.frame = NSRect(x: 0, y: topInset, width: stage.bounds.width, height: max(0, stage.bounds.height - topInset)) }
        guard emptyGlass.isHidden == empty || pageHost.isHidden != empty else { return }
        emptyGlass.isHidden = !empty
        pageHost.isHidden = empty
    }
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
    private lazy var zoomToast = ZoomToast(reset: { [weak self] in self?.actualSize(nil) })
    /// The zoom toast, for the page in front, after you changed its zoom.
    /// The tab in front shows it too, for as long as you're zooming.
    private func showZoom(up: Bool?) {
        guard let tab = selected, let webView = tab.webView, fullScreenPage == nil else { return }
        madeToast?.dismiss()   // one toast at a time, in one place
        zoomToast.show(Double(webView.pageZoom), in: stage, above: madeToast ?? status)
        strip.showZoom(Int((Double(webView.pageZoom) * 100).rounded()), up: up, for: tab)
    }
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
    private weak var leaving: SillWebView?
    private var expected = Set<String>()
    private var connectAheadTimer: Timer?
    private var connectedAhead: [String: Date] = [:]
    /// What the spare is already loading, guessed from the palette's top hit.
    private var prerendered: URL?
    private var prerenderTimer: Timer?
    /// Restored tabs to load ahead once the ones next door have, latest seen first.
    private var warmAfterRestore: [Tab] = []

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
        // Opaque: the bar's glass shows the desktop behind the window all the
        // same. Rounder corners (Settings › Appearance) come from the window
        // server (applyLooks); only without that is the window see-through,
        // and a see-through window is composited whole on every frame.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        if isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        // Traffic lights, as any Mac window has. An empty unified toolbar
        // makes the title bar the bar's height, so macOS centres them in it.
        let toolbar = NSToolbar(identifier: popup ? "popup" : "browser")
        toolbar.showsBaselineSeparator = false
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // The toolbar makes the whole bar a place macOS drags the window
        // from by itself, before Sill sees the mouse: dragging a tab to
        // reorder it dragged the window. Sill moves the window itself, from
        // the bar's bare glass only (TopBar, TabStripView). Only while the
        // pointer is over the tabs: a window that is never movable can't
        // Fill, Center or tile (TabStripView.mouseEntered).
        super.init(window: window)
        window.delegate = self

        strip.browser = self
        stage.wantsLayer = true
        // Rounder than the system's window corners where the window server
        // can't round them; the shadow of a see-through window follows what
        // it draws, so it follows these.
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
        status.toastFrame = { [weak self] in
            guard let self else { return nil }
            if let frame = self.zoomToast.shownFrame { return frame }
            if let toast = self.madeToast, !toast.isHidden { return toast.frame }
            return nil
        }
        watchForPeek()
        stage.onLayout = { [weak self] in self?.stageLaidOut() }
        // The Find bar, the palette and its settings are built ahead of their
        // first use, not on the first ⌘F, ⌘T or ⌘, (cold, each cost 50 to 110
        // ms, measured). Each part on a quiet moment of its own: see readyAhead.
        readyAhead(step: 0, since: CACurrentMediaTime())

        bar.back.target = self
        bar.back.action = #selector(goBack(_:))
        bar.forward.target = self
        bar.forward.action = #selector(goForward(_:))
        bar.reload.target = self
        bar.reload.action = #selector(reloadOrStop(_:))
        bar.isPopup = isPopup
        if isPrivate { bar.profile.markPrivate() }
        bar.extensions.target = self
        bar.extensions.action = #selector(showExtensions(_:))
        bar.profile.target = self
        bar.profile.action = #selector(showProfile(_:))
        bar.downloads.target = self
        bar.downloads.action = #selector(showDownloads(_:))
        bar.add.target = self
        bar.add.action = #selector(newTab(_:))
        bar.allTabs.target = self
        bar.allTabs.action = #selector(showAllTabs(_:))
        // A file or link dropped on the bar: a new tab each, where it was let
        // go, the last one in front. (A popup's bar holds only its one page.)
        if !isPopup {
            bar.onDrop = { [weak self] urls, index in
                guard let self else { return }
                var at = index
                for (n, url) in urls.enumerated() {
                    let tab = self.addTab(url: url, at: at, select: n == urls.count - 1)
                    if let placed = self.tabs.firstIndex(where: { $0 === tab }) { at = placed + 1 }
                }
            }
        }
        updateNavigation()
        applyLooks()
        // Settings apply as they change, to every window.
        // Only what a change touches is redone: a switch for the ad blocker
        // doesn't recompute the window's shadow or lay the tabs out again.
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

    /// What the window's look depends on, to tell which parts a change of
    /// settings touched.
    private struct Looks: Equatable {
        var theme: Theme, glassWash: Double, glassBar: Bool
        var roundCorners: Bool, cornerRadius: Double
        var tabWidth: TabWidth, closeButtons: CloseButtons, tabPreviews: Bool
        init(_ p: Preferences) {
            theme = p.theme; glassWash = p.glassWash; glassBar = p.glassBar
            roundCorners = p.roundCorners; cornerRadius = p.cornerRadius
            tabWidth = p.tabWidth; closeButtons = p.closeButtons; tabPreviews = p.showsTabPreviews
        }
    }

    private func applyLooks() {
        let prefs = Preferences.shared
        let looks = Looks(prefs)
        let before = appliedLooks
        guard looks != before else { return }
        appliedLooks = looks
        if before?.theme != looks.theme, !isPrivate {
            window?.appearance = prefs.theme.appearance
            madePalette?.takeAppearance(of: window)
        }
        if before?.tabWidth != looks.tabWidth || before?.closeButtons != looks.closeButtons || before?.tabPreviews != looks.tabPreviews {
            strip.prefsChanged()
        }
        guard before?.glassWash != looks.glassWash || before?.glassBar != looks.glassBar
            || before?.roundCorners != looks.roundCorners || before?.cornerRadius != looks.cornerRadius
            || before?.theme != looks.theme else { return }
        let amount = CGFloat(prefs.glassWash)
        wash.effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(amount).cgColor
        }
        ground.isHidden = !prefs.glassBar
        // No wash at all is no layer to blend.
        wash.isHidden = !prefs.glassBar || amount == 0
        let round = prefs.roundCorners
        // Rounder corners from the window server, as every window's own
        // corners are: the window stays opaque, nothing in it is clipped, and
        // the shadow and rim follow. Measured on a page scrolling itself for
        // five seconds: steady 60 fps, worst frame 22-28 ms rather than
        // 35-490, and a fifth less WindowServer time than clipping it here.
        // (Square while on a full screen, whatever is set meanwhile.)
        let full = window?.styleMask.contains(.fullScreen) == true
        if setCornerRadius(round ? (full ? 0 : prefs.cornerRadius) : nil) {
            window?.isOpaque = true
            window?.backgroundColor = .windowBackgroundColor
            stage.layer?.cornerRadius = 0
            stage.layer?.backgroundColor = nil
            Self.clip(top, radius: 0, corners: .top)
            Self.clip(pageHost, radius: 0, corners: .bottom)
            if before?.roundCorners != looks.roundCorners || before?.cornerRadius != looks.cornerRadius {
                window?.invalidateShadow()
            }
            return
        }
        // Without it: a see-through window, clipped to them. Only the
        // corners are clipped: the bar's top two and the page's bottom two.
        // A rounded mask over the whole window, page and all, made every
        // frame of a scrolling page or a video go through an extra offscreen pass.
        let radius = round ? prefs.cornerRadius : 0
        window?.isOpaque = !round
        window?.backgroundColor = round ? .clear : .windowBackgroundColor
        // Its own background follows the radius without clipping anything.
        stage.layer?.cornerRadius = radius
        stage.layer?.masksToBounds = false
        stage.layer?.backgroundColor = round && !prefs.glassBar ? NSColor.windowBackgroundColor.cgColor : nil
        Self.clip(top, radius: radius, corners: .top)
        Self.clip(pageHost, radius: radius, corners: .bottom)
        if before?.roundCorners != looks.roundCorners || before?.cornerRadius != looks.cornerRadius {
            window?.invalidateShadow()
        }
    }
    private var appliedLooks: Looks?
    /// The system's radius for this window, from before Sill changed it.
    private var systemCornerRadius: Double?

    /// Asks the window server to round the window at `radius`, or puts the
    /// system's own corners back for nil. False where it can't be asked (the
    /// setting lives outside the public framework), and the caller clips.
    private func setCornerRadius(_ radius: Double?) -> Bool {
        let get = NSSelectorFromString("_cornerRadius"), set = NSSelectorFromString("_setCornerRadius:")
        // Only as the two were found: a number out, a number in. Either
        // changed, and they're left alone rather than called the wrong way.
        guard let window, window.responds(to: get), window.responds(to: set),
              Self.shape(of: get, in: window) == "d16@0:8", Self.shape(of: set, in: window) == "v24@0:8d16"
        else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Double
        typealias Setter = @convention(c) (AnyObject, Selector, Double) -> Void
        let current = unsafeBitCast(window.method(for: get), to: Getter.self)(window, get)
        if systemCornerRadius == nil {
            // Never changed and not asked to be: the system's corners, untouched.
            guard radius != nil else { return true }
            systemCornerRadius = current
        }
        let wanted = radius ?? systemCornerRadius ?? current
        if current != wanted { unsafeBitCast(window.method(for: set), to: Setter.self)(window, set, wanted) }
        return true
    }

    /// What a method takes and gives back, as the runtime records it.
    private static func shape(of selector: Selector, in object: AnyObject) -> String? {
        guard let method = class_getInstanceMethod(type(of: object), selector),
              let types = method_getTypeEncoding(method) else { return nil }
        return String(cString: types)
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

    /// A download began: the list opens, unless it's open already or the
    /// window is out of sight.
    func revealDownloads() {
        guard downloadsPopover?.isShown != true, !isPopup, fullScreenPage == nil,
              let window, window.isVisible, !window.isMiniaturized else { return }
        showDownloads(nil)
    }

    @objc func showDownloads(_ sender: Any?) {
        if downloadsPopover?.isShown == true { downloadsPopover?.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        // Measured before it shows: a popover that shrinks after appearing
        // shrinks from the top, and lands far below its button.
        let host = NSHostingController(rootView: DownloadsView(isPrivate: isPrivate).modifier(PanelBacking()))
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

    private var extensionsPopover: NSPopover?

    /// The Extensions button: what's installed, on or off, and each one's controls.
    @objc func showExtensions(_ sender: Any?) {
        if extensionsPopover?.isShown == true { extensionsPopover?.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        let site = selected?.webView?.url.flatMap { $0.scheme?.hasPrefix("http") == true ? $0.host() : nil }
        let host = NSHostingController(rootView: ExtensionsView(open: { [weak self, weak popover] url in
            popover?.close()
            _ = self?.addTab(url: url)
        }, site: site, reload: { [weak self] in self?.selected?.webView?.reload() }).modifier(PanelBacking()))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        extensionsPopover = popover
        popover.show(relativeTo: bar.extensionsRect, of: bar, preferredEdge: .maxY)
    }

    /// A sign-in in one of this window's tabs went through: Sill's glass
    /// menu, from the profile button (where Passwords lives), while that tab
    /// is in front. A click elsewhere is Not Now.
    func offerToSavePassword(for tab: Tab, host: String, user: String, password: String, update: Bool) {
        guard tab === selected, let window, window.isVisible else { return }
        let site = Domains.bare(host)
        var entries: [GlassMenu.Entry] = [
            .item(.init(title: update ? "Update Password" : "Save Password", symbol: "key.fill", keys: ["↩"],
                        subtitle: user.isEmpty ? nil : user) { [weak self] in
                Task { @MainActor [weak self] in
                    guard await SavedPasswords.save(password, user: user, host: host) != .failed else { return }
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                    self?.toast(update ? "Password updated" : "Password saved")
                }
            }),
            .item(.init(title: "Not Now", symbol: "xmark") {}),
        ]
        if !update {
            entries += [.separator, .item(.init(title: "Never for This Website", symbol: "nosign") { SavedPasswords.setNever(for: host) })]
        }
        let anchor = bar.convert(bar.profileRect, to: nil)
        GlassMenu(title: update ? "Update your password for \(site)?" : "Save your password for \(site)?", entries: entries, searchable: false)
            .show(in: window, at: NSPoint(x: anchor.maxX, y: anchor.minY - 6), alignRight: true, from: bar.profile)
    }

    /// The profile button: who's browsing, and the browser's everyday places.
    @objc func showProfile(_ sender: Any?) {
        guard let window, GlassMenu.shouldOpen(from: bar.profile) else { return }
        let entries: [GlassMenu.Entry] = [
            .item(.init(title: "New Window", symbol: "macwindow", keys: ["⌘", "N"]) { AppDelegate.shared.newWindow(nil) }),
            .item(.init(title: "New Private Window", symbol: "eye.slash", keys: ["⇧", "⌘", "N"]) { AppDelegate.shared.newPrivateWindow(nil) }),
            .separator,
            .item(.init(title: "History", symbol: "clock", keys: ["⌘", "Y"]) { [weak self] in self?.showHistory(nil) }),
            .item(.init(title: "Downloads", symbol: "arrow.down.circle") { [weak self] in self?.showDownloads(nil) }),
            .item(.init(title: "Extensions", symbol: "puzzlepiece.extension") { [weak self] in self?.showExtensions(nil) }),
            .item(.init(title: "Passwords", symbol: "key") { PasswordsWindow.show() }),
            .item(.init(title: "Import Passwords from Dia…", symbol: "square.and.arrow.down", isEnabled: DiaImport.available) { [weak self] in
                self?.importFromDia()
            }),
            .separator,
            .item(.init(title: "Settings…", symbol: "gearshape", keys: ["⌘", ","]) { AppDelegate.shared.showSettings(nil) }),
        ]
        let anchor = bar.convert(bar.profileRect, to: nil)
        GlassMenu(title: Profile.name, entries: entries, searchable: false)
            .show(in: window, at: NSPoint(x: anchor.maxX, y: anchor.minY - 6), alignRight: true, from: bar.profile)
    }

    /// Dia's saved passwords into Sill's. macOS asks first whether Sill may
    /// read the key Dia keeps them under.
    func importFromDia() {
        toast("Importing passwords from Dia…")
        Task { @MainActor in
            switch await DiaImport.run() {
            case let .imported(added, updated, _):
                let total = added + updated
                toast(total == 0 ? "Your Dia passwords are already in Sill" : "Imported \(total) password\(total == 1 ? "" : "s") from Dia")
            case .noAccess: toast("Sill wasn’t allowed to read Dia’s passwords")
            case .nothing: toast("Dia has no saved passwords")
            case .failed(let why): toast("Couldn’t import from Dia: \(why)")
            }
        }
    }

    @objc func showAllTabs(_ sender: Any?) {
        showPalette(.tabs)
    }

    /// ⌘Y: history, searchable, in the palette.
    @objc func showHistory(_ sender: Any?) {
        showPalette(.history)
    }

    /// History › Clear History…: ⌘Y, with how far back to clear asked at once.
    @objc func clearHistory(_ sender: Any?) {
        if !(paletteOpen && palette.mode == .history) { showPalette(.history) }
        DispatchQueue.main.async { [weak self] in self?.palette.showClearMenu() }
    }

    private func updateNavigation() {
        bar.back.isEnabled = selected?.canGoBack ?? false
        bar.forward.isEnabled = selected?.canGoForward ?? false
        bar.isLoading = selected?.isLoading ?? false
    }

    // MARK: - Layout

    /// The page's own full screen (a video) hides the bar: the page has the window.
    var topInset: CGFloat { fullScreenPage == nil ? TopBar.height : 0 }

    private func stageLaidOut() {
        if loadingLine.superview !== stage { stage.addSubview(loadingLine) }
        loadingLine.frame = NSRect(x: 0, y: TopBar.height - LoadingLine.thickness, width: stage.bounds.width, height: LoadingLine.thickness)
        // Back and forward start after the traffic lights where there are some.
        if let window, let zoom = window.standardWindowButton(.zoomButton), !zoom.isHidden,
           !window.styleMask.contains(.fullScreen) {
            bar.leadingInset = zoom.convert(zoom.bounds, to: nil).maxX + 6
        } else {
            bar.leadingInset = 0
        }
        top.isHidden = fullScreenPage != nil
        if fullScreenPage != nil { loadingLine.isHidden = true }
        top.frame = NSRect(x: 0, y: 0, width: stage.bounds.width, height: TopBar.height)
        bar.frame = top.bounds
        // The page starts below the bar: nothing goes behind the glass.
        pageHost.frame = NSRect(x: 0, y: topInset, width: stage.bounds.width, height: max(0, stage.bounds.height - topInset))
        // Only as tall as the bar plus a margin the page covers: its rim stays
        // hidden under the page, and no glass is drawn where none is seen.
        ground.frame = NSRect(x: 0, y: 0, width: stage.bounds.width, height: TopBar.height)
        wash.frame = ground.frame
        showEmptyGlass()
        madePalette?.stageResized(stage)
        if let findBar = madeFindBar, findBar.isOpen { findBar.place(in: stage, top: topInset) }
        // Out of sight it's placed when next shown, not measured each frame of a resize.
        if !status.isHidden { status.place(in: stage) }
        zoomToast.place(in: stage)
        if let toast = madeToast, !toast.isHidden { toast.place(in: stage) }
        placePrompts()
    }

    func windowDidResize(_ notification: Notification) {
        hidePreview(animated: false)
        stage.needsLayout = true
    }
    func windowDidEnterFullScreen(_ notification: Notification) { stage.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        if fullScreenPage == nil, window?.toolbar?.isVisible == false { window?.toolbar?.isVisible = true }
        stage.needsLayout = true
        keepCorners()
    }
    /// In full screen the toolbar (there for the traffic lights) hides with
    /// the menu bar: kept, it was a blank strip over the top of the bar.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposed.union([.fullScreen, .autoHideMenuBar, .autoHideToolbar])
    }
    func windowDidChangeScreen(_ notification: Notification) { keepCorners() }
    /// Rounder corners asked for again where AppKit might set its own. A
    /// probe kept them through appearance changes, minimise and restore,
    /// sheets, toolbars, style and key changes and moves; a second screen
    /// and the way back from full screen weren't there to try. Only a
    /// comparison when they stuck.
    private func keepCorners() {
        guard Preferences.shared.roundCorners, window?.styleMask.contains(.fullScreen) == false else { return }
        _ = setCornerRadius(Preferences.shared.cornerRadius)
    }
    // Square on a full screen, as every window is; round again on the way back.
    func windowWillEnterFullScreen(_ notification: Notification) {
        if Preferences.shared.roundCorners { _ = setCornerRadius(0) }
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        if Preferences.shared.roundCorners { _ = setCornerRadius(Preferences.shared.cornerRadius) }
        // Out of full screen another way (⌃⌘F, the green button): the page
        // leaves its own full screen too.
        if let page = fullScreenPage {
            fullScreenPage = nil
            enteredForPage = false
            page.webView?.exitFullScreen()
            stage.needsLayout = true
        }
        window?.toolbar?.isVisible = true
    }

    /// A page in its own full screen (a video), and whether the window went
    /// full screen for it (and so leaves it with it).
    func pageFullScreen(_ tab: Tab, _ on: Bool) {
        guard let window else { return }
        if on {
            guard tab === selected else { tab.webView?.exitFullScreen(); return }
            fullScreenPage = tab
            zoomToast.hide()
            madeToast?.dismiss()
            downloadsPopover?.close()
            // The window's (empty) toolbar stays as a blank strip over the
            // top of the screen in full screen: none while a page fills it.
            window.toolbar?.isVisible = false
            if !window.styleMask.contains(.fullScreen) { enteredForPage = true; window.toggleFullScreen(nil) }
        } else {
            guard fullScreenPage === tab else { return }
            fullScreenPage = nil
            if enteredForPage, window.styleMask.contains(.fullScreen) {
                enteredForPage = false
                window.toggleFullScreen(nil)   // the toolbar comes back once out (windowDidExitFullScreen)
            } else {
                window.toolbar?.isVisible = true
            }
        }
        stage.needsLayout = true
    }

    // MARK: - Tabs

    func restore(_ states: [SessionTab], selectedIndex: Int, splits saved: [SessionSplit] = []) {
        // The icons on disk, if they are nearly read: the row comes up with them.
        Favicons.shared.settle(within: 0.03)
        tabs = states.compactMap { state in
            guard let url = URL(string: state.url) else { return nil }
            let tab = Tab(url: url, title: state.title, isPrivate: isPrivate)
            tab.host = self
            tab.seenAt = state.shown.map { Date(timeIntervalSince1970: $0) }
            return tab
        }
        warmAfterRestore = tabs.filter { $0.seenAt != nil }.sorted { $0.seenAt! > $1.seenAt! }
        strip.sync(animated: false)
        // The splits you left, as you left them: in place before the tab in
        // front is chosen, so that tab comes up already beside its partner.
        if tabs.count == states.count {
            for saved in saved where saved.left != saved.right
                && tabs.indices.contains(saved.left) && tabs.indices.contains(saved.right) {
                let left = tabs[saved.left], right = tabs[saved.right]
                guard split(of: left) == nil, split(of: right) == nil else { continue }
                let pair = SplitPair(left: left, right: right)
                pair.fraction = CGFloat(min(max(saved.fraction, 0.15), 0.85))
                splits.append(pair)
            }
            showPairs()
        }
        if tabs.indices.contains(selectedIndex) { select(tabs[selectedIndex]) } else if let first = tabs.first { select(first) }
    }

    @discardableResult
    func addTab(url: URL?, configuration: WKWebViewConfiguration? = nil, adopting popupView: SillWebView? = nil, at index: Int? = nil,
                select shouldSelect: Bool = true, opener: Tab? = nil, typed: Bool = false, state: Any? = nil) -> Tab {
        let tab = Tab(url: nil, isPrivate: isPrivate)
        tab.host = self
        tab.opener = opener
        var index = min(index ?? tabs.count, tabs.count)
        // Never between the two halves of a split: a link from the left one
        // opens after the pair, which stays together.
        for pair in splits {
            if let left = pair.left, let right = pair.right,
               let l = tabs.firstIndex(where: { $0 === left }), let r = tabs.firstIndex(where: { $0 === right }),
               r == l + 1, index == r {
                index = r + 1
            }
        }
        tabs.insert(tab, at: index)
        if let popupView {
            tab.adopt(popupView, popup: true)
        } else if let configuration {
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
                // A view that loaded some other site (the palette's guess
                // before the last letters) is not used: it would show that
                // site until this one drew.
                let others = !ready && prerendered != nil
                spare = nil
                prerendered = nil
                if others { view.stopLoading(); view.removeFromSuperview(); tab.materialize() } else { tab.adopt(view, loaded: ready) }
            }
        }
        if shouldSelect { select(tab, animated: true) } else { strip.sync(animated: true) }
        changed()
        return tab
    }

    func select(_ tab: Tab, animated: Bool = false) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        // A split still waiting for its second tab is given up on by going
        // to a tab that isn't in it.
        if let pending = pendingSplit, !pending.contains(tab) { pendingSplit = nil }
        if paletteOpen && selected !== tab { palette.close(animated: false, focusPage: false) }
        madeFindBar?.close()
        let previous = selected
        hidePreview(animated: false)
        // The page being left keeps its place in the window, under the new
        // one, until its video has floated off into Picture in Picture: a
        // page taken out of the window first would have it cancelled. Only
        // a page playing something is asked; any other leaves at once.
        var keep: SillWebView?
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
                // Floating: it stays in the window, drawn, under the page in front.
                if floated, old.superview === self.pageHost {
                    self.pageHost.addSubview(old, positioned: .below, relativeTo: nil)
                } else if old.superview === self.pageHost { old.park() } else { old.removeFromSuperview() }
            }
        }
        // A page in its own full screen leaves it when another tab comes in.
        if let page = fullScreenPage, page !== tab { page.webView?.exitFullScreen() }
        // Pictured as it's left, while still on screen: Chromium can't picture
        // a page it has hidden, and its hover card would be blank. Kept small.
        if let previous, previous !== tab, previous.webView?.isShown == true {
            previous.capturePicture { [weak previous] image in
                if let image { previous?.keepWhileAsleep(image) }
            }
        }
        selected = tab
        tab.lastShown = Date()
        let webView = tab.materialize()
        placePages(keep: keep)
        showEmptyGlass()
        loadingLine.show(progress: tab.progress, loading: tab.isLoading, jump: true)
        tab.reloadIfCrashed()
        tab.loadIfEmpty()
        // Back from picture in picture: WebKit puts a video back in its page
        // only once that page is in the window, so after it is.
        if tab === pictured {
            pictured = nil
            PictureInPicture.return(to: tab)
        }
        // Clicks, ⌘1–9 and ⌃Tab only move the selection; a tab added or
        // closed changes the row.
        if strip.matches(tabs) { strip.select(tab) } else { strip.sync(animated: animated) }
        showPairs()
        warmNeighbours(of: tab)
        window?.title = tab.displayTitle
        updateNavigation()
        zoomToast.hide()
        status.show(nil)
        hoveredLink = nil
        endPeek()
        if !paletteOpen { window?.makeFirstResponder(webView) }
        changed()
    }

    /// Closes `tab`, once its page has had its say: one with something
    /// unsaved asks first, and stays if you say so.
    func close(_ tab: Tab) {
        tab.mayClose { [weak self] may in
            if may { self?.closeNow(tab) }
        }
    }

    /// Asks every page in turn whether it may go; `done` may run before this returns.
    func mayCloseAll(_ done: @escaping (Bool) -> Void) {
        var waiting = tabs[...]
        func next() {
            guard let tab = waiting.popFirst() else { return done(true) }
            tab.mayClose { $0 ? next() : done(false) }
        }
        next()
    }

    /// The window's close button, or Close Window: as for closing each tab.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        var answer: Bool?
        var returned = false
        mayCloseAll { [weak self] may in
            if returned { if may { self?.window?.close() } } else { answer = may }
        }
        returned = true
        return answer ?? false
    }

    func closeNow(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.dropAsks()
        hidePreview(animated: false)
        if let url = tab.webView?.url ?? tab.url, !isPrivate {
            closed.append((url, tab.displayTitle, index, tab.interactionState))
            if closed.count > 30 { closed.removeFirst() }
        }
        tabs.remove(at: index)
        // A split loses one side: the page left over has the window to itself.
        // A split loses one side: the page left over has the window to
        // itself, and if that split was on screen, the window shows so.
        let splitShown = split?.contains(tab) == true
        if split(of: tab) != nil || pendingSplit?.contains(tab) == true { dissolveSplit(of: tab); showPairs() }
        if splitShown, selected !== tab, !tabs.isEmpty { placePages(keep: nil) }
        // Its sound and video go with it, floating or not: nothing keeps
        // playing from a tab that's gone.
        if pictured === tab { pictured = nil }
        PictureInPicture.return(to: tab)
        Self.silence(tab)
        Web.releaseIdleProcesses(soon: false)
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

    /// Takes `tab` out of this window with its page alive, for another
    /// window to take (a tab dragged out of the row). The last tab out
    /// closes the window.
    /// `keepingPage`: its page has already gone into another window (it
    /// isn't taken out of that one).
    func release(_ tab: Tab, keepingPage: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        hidePreview(animated: false)
        tab.dropAsks()
        tabs.remove(at: index)
        // A split loses one side: the page left over has the window to
        // itself, and if that split was on screen, the window shows so.
        let splitShown = split?.contains(tab) == true
        if split(of: tab) != nil || pendingSplit?.contains(tab) == true { dissolveSplit(of: tab); showPairs() }
        if splitShown, selected !== tab, !tabs.isEmpty { placePages(keep: nil) }
        if pictured === tab { pictured = nil }
        if !keepingPage { tab.webView?.removeFromSuperview() }
        let wasFront = selected === tab
        // Not "the page being left": it isn't, it's going on to another window.
        if wasFront { selected = nil }
        if tabs.isEmpty {
            // Closed a moment later: a window closing with the page still
            // settling into its new one left that page blank there.
            DispatchQueue.main.async { [weak self] in self?.window?.close() }
            return
        }
        if wasFront { select(tabs[min(index, tabs.count - 1)], animated: true) } else { strip.sync(animated: true) }
        changed()
    }

    /// A tab from another window, page and all, in front at `index`.
    func take(_ tab: Tab, at index: Int? = nil) {
        tab.host = self
        var index = min(index ?? tabs.count, tabs.count)
        // Never between the two halves of a split: after the pair instead.
        for pair in splits {
            if let left = pair.left, let right = pair.right,
               let l = tabs.firstIndex(where: { $0 === left }), let r = tabs.firstIndex(where: { $0 === right }),
               r == l + 1, index == r {
                index = r + 1
            }
        }
        tabs.insert(tab, at: index)
        select(tab, animated: true)
        changed()
    }

    /// A tab dragged off the row. One of several goes into a window of its
    /// own; a window's only tab brings its window along. Either way the
    /// window follows the pointer until it's let go, and let go over another
    /// Sill window's tabs, the tab joins them there (its window closing if
    /// it's left empty). `grab` is where the pointer holds the window, in
    /// window coordinates.
    func tearOff(_ tab: Tab, grab: NSPoint) {
        guard let window, tabs.contains(where: { $0 === tab }) else { return }
        let carrier: BrowserWindowController
        if tabs.count > 1 {
            carrier = AppDelegate.shared.makeBrowser(isPrivate: isPrivate)
            guard let newWindow = carrier.window else { return }
            newWindow.setFrame(window.frame, display: false)
            release(tab)
            carrier.take(tab)
        } else {
            carrier = self
        }
        carry(tab, in: carrier, grab: grab)
    }

    private func carry(_ tab: Tab, in carrier: BrowserWindowController, grab: NSPoint) {
        guard let moving = carrier.window else { return }
        let app = AppDelegate.shared
        /// The window whose row of tabs is under the pointer, if any but the carried one.
        func target(at mouse: NSPoint) -> (BrowserWindowController, Int)? {
            for other in app.browsers where other !== carrier && !other.isPopup && other.isPrivate == carrier.isPrivate {
                guard let otherWindow = other.window, otherWindow.isVisible, !otherWindow.isMiniaturized,
                      otherWindow.frame.contains(mouse) else { continue }
                let point = other.strip.convert(otherWindow.convertPoint(fromScreen: mouse), from: nil)
                // The row and a little either side of it, so it needn't be hit exactly.
                if other.strip.bounds.insetBy(dx: 0, dy: -14).contains(point) {
                    return (other, other.strip.dropIndex(at: point.x))
                }
            }
            return nil
        }
        func follow() {
            let mouse = NSEvent.mouseLocation
            moving.setFrameTopLeftPoint(NSPoint(x: mouse.x - grab.x, y: mouse.y + (moving.frame.height - grab.y)))
            // See-through over a row it can join, so that row shows where it goes.
            let over = target(at: mouse) != nil
            let alpha: CGFloat = over ? 0.45 : 1
            if moving.alphaValue != alpha { moving.alphaValue = alpha }
        }
        follow()
        carrier.showWindow(nil)
        moving.makeKeyAndOrderFront(nil)
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                          inMode: .eventTracking, dequeue: true) {
            if event.type == .leftMouseUp { break }
            follow()
        }
        moving.alphaValue = 1
        carrier.strip.syncMovable()
        strip.syncMovable()
        if let (other, index) = target(at: NSEvent.mouseLocation) {
            // Into its new window first, then out of the old one (which
            // closes if that was its last tab): the other way round, the
            // page stayed blank in its new window.
            other.take(tab, at: index)
            carrier.release(tab, keepingPage: true)
            other.window?.makeKeyAndOrderFront(nil)
            other.strip.syncMovable()
        }
    }

    func move(_ tab: Tab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(index, tabs.count))
        if keepPairTogether(moved: tab) { strip.sync(animated: true) }
        changed()
    }

    /// The two halves of a split sit side by side in the row, left then
    /// right. One dragged away brings the other along; a tab dropped between
    /// them ends up after the pair. Whether anything had to move.
    @discardableResult
    private func keepPairTogether(moved: Tab?) -> Bool {
        var changed = false
        for pair in splits {
            guard let left = pair.left, let right = pair.right,
                  let l = tabs.firstIndex(where: { $0 === left }), let r = tabs.firstIndex(where: { $0 === right }),
                  r != l + 1 else { continue }
            if moved === right {
                tabs.remove(at: l)
                tabs.insert(left, at: tabs.firstIndex(where: { $0 === right }) ?? r)
            } else {
                tabs.remove(at: r)
                tabs.insert(right, at: (tabs.firstIndex(where: { $0 === left }) ?? l) + 1)
            }
            changed = true
        }
        return changed
    }

    func navigate(to url: URL, newTab: Bool, typed: Bool) {
        if ChromiumSettings.open(url) { return }
        if newTab || selected == nil {
            addTab(url: url, typed: typed)
        } else {
            selected?.load(url, typed: typed)
            if let webView = selected?.webView { window?.makeFirstResponder(webView) }
        }
    }

    private func changed() { onChange?() }

    // MARK: - Palette

    /// Builds the window's overlays ahead of their first use, one part per
    /// quiet moment: the Find bar, then the palette, each made and then put
    /// in the window, then the palette's settings. A moment is quiet once
    /// the page in front has loaded (or ten seconds have gone by) and nothing
    /// has been pressed, typed or scrolled for 0.4 s. At a fixed two seconds
    /// they often landed on the first page's load or its first scroll; one
    /// part at a time, no single turn holds the main thread for long.
    private func readyAhead(step: Int, since start: CFTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let window = self.window else { return }
            let waited = CACurrentMediaTime() - start
            // A window never shown (or long hidden) builds them when first wanted.
            guard waited < 120 else { return }
            let idle = ProcessInfo.processInfo.systemUptime - (NSApp.currentEvent?.timestamp ?? 0)
            let quiet = waited > 1 && window.isVisible && idle > 0.4
                && (self.selected?.isLoading != true || waited > 10)
                // Not in the middle of a resize, a drag or an open menu.
                && RunLoop.main.currentMode == .default
            guard quiet else { return self.readyAhead(step: step, since: start) }
            switch step {
            case 0: _ = self.findBar
            case 1: self.findBar.ready(in: self.stage, top: self.topInset)
            case 2 where !self.isPopup: _ = self.palette
            case 3 where !self.isPopup: self.palette.ready(in: self.stage)
            case 4 where !self.isPopup: self.palette.readySettings()
            default: return
            }
            self.readyAhead(step: step + 1, since: start)
        }
    }

    /// The palette, turned to its settings.
    func showSettings() {
        if !paletteOpen { showPalette(.newTab); palette.showSettings(true, animated: false) } else { palette.showSettings(true) }
    }

    func showPalette(_ mode: Palette.Mode) {
        hidePreview(animated: false)
        if paletteOpen && palette.mode == mode && (mode == .newTab || mode == .history) { palette.close(); return }
        status.show(nil)
        endPeek()
        palette.open(mode, in: stage)
        if mode == .newTab, spare == nil {
            // Once the palette's first frame is committed: made on the next
            // turn instead, a web view (5 to 75 ms, its process started with
            // it) ran before that frame and held the palette back.
            Frame.afterCommit { [weak self] in
                guard let self, self.spare == nil, self.window?.isVisible == true else { return }
                self.spare = SillWebView(frame: self.pageBounds, configuration: Web.configuration(private: self.isPrivate))
                // Starts its web process now, not at Return: no page is loaded.
                self.spare?.evaluateJavaScript("", completion: nil)
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
        guard let url, paletteOpen, palette.mode != .tabs, !isPrivate, let host = url.host() else { return }
        let newTab = palette.mode == .newTab
        if newTab, WarmSite.handles(url), Preferences.shared.keepsClaudeReady { return }
        // A site you haven't been to isn't loaded ahead, nor anything typed
        // into the address field (⌘L), which replaces the page in front; but
        // the way there is opened (and to its www., where most bare names
        // send you), so the lookup and handshake are done by Return. After
        // the same pause, or a longer one for a name that may be on its way
        // to another: nytimes.co, typed on the way to nytimes.com.
        guard newTab, History.shared.knows(host: host) else {
            let last = host.split(separator: ".").last.map(String.init) ?? ""
            let unfinished = ["com", "org", "net"].contains { $0.count > last.count && $0.hasPrefix(last) }
            prerenderTimer = Timer.scheduledTimer(withTimeInterval: unfinished ? 0.4 : 0.08, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.paletteOpen else { return }
                    self.expect(url)
                    if host.split(separator: ".").count == 2 { self.expect(URL(string: "https://www.\(host)/")) }
                }
            }
            return
        }
        // Never a plain-HTTP page that is asked about first: the spare view asks nothing.
        guard url.scheme == "https" || !SitePermissions.asksBeforeHTTP(host) else { return }
        if let prerendered, Self.samePage(prerendered, url) { return }
        prerenderTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.paletteOpen else { return }
                let view = self.spare ?? SillWebView(frame: self.pageBounds, configuration: Web.configuration(private: self.isPrivate))
                self.spare = view
                self.prerendered = url
                view.stopLoading()
                Shield.shared.whenReady { [weak view] in view?.load(URLRequest(url: url)) }
                // Drawing as it comes in, under the page in front: Return
                // shows it as it is, rather than after its first drawing.
                self.drawAhead(view, live: true)
            }
        }
    }

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String {
            Domains.bare(url.host()) + (url.path == "/" ? "" : url.path) + (url.query.map { "?" + $0 } ?? "")
        }
        return key(a) == key(b)
    }

    func paletteClosed(focusPage: Bool = true) {
        expected = []
        if focusPage, let webView = selected?.webView { window?.makeFirstResponder(webView) }
        // A spare nobody took (the palette was cancelled) gives its page back.
        // Later in the turn, so the Return that closed the palette can claim it.
        // One with no page stays: its process is the started one the next tab
        // would have had, and letting it go leaves that tab to start its own.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.paletteOpen else { return }
            self.prerenderTimer?.invalidate()
            guard self.prerendered != nil else { return }
            self.spare?.stopLoading()
            self.spare?.removeFromSuperview()
            self.spare = nil
            self.prerendered = nil
        }
    }

    var paletteIsOpen: Bool { paletteOpen }

    // MARK: - Window

    /// WebKit knows whether a page is making sound; it just doesn't say so publicly.
    /// Its video's picture in picture closed: back in front, or put aside.
    func floatEnded(_ tab: Tab) {
        if pictured === tab { pictured = nil }
        guard let view = tab.webView, tab !== selected, split?.contains(tab) != true else { return }
        if view.superview === pageHost { view.park() }
    }

    private static func isPlayingAudio(_ webView: SillWebView) -> Bool {
        let key = "_isPlayingAudio"
        // Chromium: what the page script says. (Answering "yes" here, as
        // this once did, kept every page from napping and every tab switch
        // from holding the page being left until the new one had drawn.)
        guard webView.responds(to: NSSelectorFromString(key)) else { return webView.tab?.audible ?? false }
        return (webView.value(forKey: key) as? Bool) ?? true
    }

    /// Puts tabs idle for `olderThan` seconds (the setting, unless the Mac is
    /// short of memory and asks sooner) to sleep. Never one on screen (the
    /// one in front, or the other half of its split), one whose video
    /// floats, or one playing sound or using the camera.
    func napIdleTabs(olderThan: TimeInterval? = nil) {
        // Short of memory, the page kept ready for a new tab goes too.
        if olderThan != nil, !paletteOpen { spare?.removeFromSuperview(); spare = nil }
        guard Preferences.shared.sleepsTabs else { return }
        let after = olderThan ?? TimeInterval(max(5, Preferences.shared.sleepAfterMinutes) * 60)
        // One at a time, a moment apart, each asked again when its turn
        // comes: a page let go costs the main thread a few milliseconds (its
        // picture, its history, its view taken down), and a window of tabs
        // going at once, as memory runs short, was a hitch of its own.
        var turn: TimeInterval = 0
        for tab in tabs where mayNap(tab, after: after) {
            DispatchQueue.main.asyncAfter(deadline: .now() + turn) { [weak self, weak tab] in
                guard let self, let tab, self.tabs.contains(where: { $0 === tab }), self.mayNap(tab, after: after) else { return }
                tab.sleepUnlessTyping()
            }
            turn += 0.15
        }
    }

    private func mayNap(_ tab: Tab, after: TimeInterval) -> Bool {
        // A floating video may be muted, so not "playing audio": it counts anyway.
        guard tab !== selected, tab !== pictured, let webView = tab.webView, !webView.isShown,
              Date().timeIntervalSince(tab.lastShown) > after,
              webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none,
              webView.fullscreenState == .notInFullscreen, !Self.isPlayingAudio(webView)
        else { return false }
        return true
    }

    /// Stops everything a page is playing, ends its picture in picture, and
    /// unloads it, for a tab or window being closed.
    static func silence(_ tab: Tab) {
        tab.dropHeldPrompts()
        guard let view = tab.webView else { return }
        // A page stuck in a script never takes the unload below, and its
        // process would spin on with no tab: it is ended, now if WebKit
        // already knows, or once it finds out.
        if !view.processIsResponsive { view.endProcess() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [view] in
            if !view.processIsResponsive { view.endProcess() }
        }
        let stop = "document.querySelectorAll('video, audio').forEach(m => { try { m.pause(); } catch (_) {} });"
            + " if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});"
        view.evaluateJavaScript(stop, in: nil, in: .page) { _ in }
        view.pauseAllMediaPlayback { }
        view.closeAllMediaPresentations { }
        view.removeFromSuperview()
        // A download still running from it keeps the page (out of sight)
        // until it's done: closed, Chromium went on writing the file but
        // Sill heard no more of it, and Stop no longer stopped it.
        if Downloads.shared.isDownloading(in: view) {
            Downloads.shared.outlive(view)
            return
        }
        // Unloaded a moment later, once the pause has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak view] in
            view?.closePage()
        }
    }

    func windowWillClose(_ notification: Notification) {
        for tab in tabs { tab.dropAsks() }
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

    func windowDidBecomeKey(_ notification: Notification) {
        AppDelegate.shared.lastBrowser = self
        strip.syncMovable()
    }
    func windowDidResignKey(_ notification: Notification) { endPeek(); hidePreview(animated: false) }

    // MARK: - Context menu for a tab

    /// A tab's commands, shown in Sill's glass menu; only those that can
    /// be done now are in it.
    func menu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
            guard enabled else { return }
            menu.addItem(ClosureMenuItem(title: title, handler: handler))
        }
        let url = tab.webView?.url ?? tab.url
        add("New Tab") { [weak self] in self?.showPalette(.newTab) }
        menu.addItem(.separator())
        add("Reload") { tab.reload() }
        add("Duplicate") { [weak self] in
            guard let self, let url, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.addTab(url: url, at: index + 1)
        }
        add("Copy Link", enabled: url != nil) { if let url { Pasteboard.copy(url) } }
        if let view = tab.webView, tab.audible || view.audioMuted {
            add(view.audioMuted ? "Unmute Tab" : "Mute Tab") { view.audioMuted.toggle() }
        }
        menu.addItem(.separator())
        if let pair = split(of: tab) {
            add("Separate Split View") { [weak self] in self?.unsplit(pair) }
        } else {
            add("Split Left") { [weak self] in self?.split(tab, onLeft: true) }
            add("Split Right") { [weak self] in self?.split(tab, onLeft: false) }
        }
        add("Move to New Window", enabled: tabs.count > 1) { [weak self] in self?.moveToNewWindow(tab) }
        // Off for the one site it broke, rather than everywhere.
        if Preferences.shared.blocksAds, let host = url?.host(), !host.isEmpty {
            let paused = Shield.shared.isPaused(on: host)
            let item = ClosureMenuItem(title: "Block Ads on \(Domains.bare(host))") { [weak tab] in
                Shield.shared.pause(host, !paused) { tab?.reload() }
            }
            item.state = paused ? .off : .on
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("Close Tab") { [weak self] in self?.close(tab) }
        add("Close Other Tabs", enabled: tabs.count > 1) { [weak self] in
            guard let self else { return }
            for other in self.tabs where other !== tab { self.close(other) }
        }
        add("Close Tabs to the Right", enabled: tabs.last !== tab) { [weak self] in
            guard let self, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            for other in self.tabs[(index + 1)...] { self.close(other) }
        }
        return menu
    }

    /// A right-click on the tab bar beside the tabs.
    func tabBarMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "New Tab") { [weak self] in self?.showPalette(.newTab) })
        if !closed.isEmpty {
            menu.addItem(ClosureMenuItem(title: "Reopen Closed Tab") { [weak self] in self?.reopenClosedTab(nil) })
        }
        return menu
    }

    /// The tab on its own in a new window, a little down and to the right of this one.
    func moveToNewWindow(_ tab: Tab) {
        guard let window, tabs.count > 1, tabs.contains(where: { $0 === tab }) else { return }
        let other = AppDelegate.shared.makeBrowser(isPrivate: isPrivate)
        guard let newWindow = other.window else { return }
        newWindow.setFrame(window.frame.offsetBy(dx: 28, dy: -28), display: false)
        release(tab)
        other.take(tab)
        other.showWindow(nil)
    }

    // MARK: - Status, toast

    func toast(_ text: String, action: (String, () -> Void)? = nil) {
        zoomToast.hide()   // one toast at a time, in one place
        let toast = madeToast ?? Toast()
        madeToast = toast
        // Over the page and the status, under the rest; over the palette
        // while it's open, so an Undo for what it just did can be clicked.
        if paletteOpen {
            if stage.subviews.last !== toast { stage.addSubview(toast, positioned: .above, relativeTo: nil) }
        } else if toast.superview !== stage || stage.subviews.firstIndex(of: toast) != stage.subviews.firstIndex(of: status).map({ $0 + 1 }) {
            stage.addSubview(toast, positioned: .above, relativeTo: status)
        }
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
    /// The bar's button: stops a page that's loading, reloads one that isn't.
    @objc func reloadOrStop(_ sender: Any?) {
        guard let tab = selected else { return }
        if tab.isLoading { tab.stop() } else { tab.reload() }
    }

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
    @objc func actualSize(_ sender: Any?) {
        selected?.webView?.pageZoom = 1
        showZoom(up: nil)
    }
    /// Chromium's own steps (90, 100, 110, 125…), as in any Chromium browser,
    /// so a figure is never 109% or 121%.
    private static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]
    private func zoom(by factor: CGFloat) {
        guard let webView = selected?.webView else { return }
        let now = webView.pageZoom
        let next = factor > 1 ? Self.zoomSteps.first { $0 > now + 0.001 } : Self.zoomSteps.last { $0 < now - 0.001 }
        webView.pageZoom = next ?? now
        showZoom(up: factor > 1)
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
            if what == .loading, tab === selected {
                loadingLine.show(progress: tab.progress, loading: tab.isLoading)
                bar.isLoading = tab.isLoading
            }
        case .progress:
            if tab === selected { loadingLine.show(progress: tab.progress, loading: tab.isLoading) }
        case .title:
            // Not a session save: titles are read when it's written, and a
            // page ticking its title would put the save off forever.
            retitle(tab)
        case .url:
            retitle(tab)
            changed()
            if tab === selected { showEmptyGlass() }
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

    func openPopup(from tab: Tab, size: NSSize) -> SillWebView? {
        let popup = AppDelegate.shared.makeBrowser(isPrivate: isPrivate, popup: true)
        guard let window = popup.window, let parent = self.window else { return nil }
        let content = NSSize(width: max(360, min(size.width, 1000)), height: max(320, min(size.height, 900)) + TopBar.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2)
        // Several at once step down and across, so none hides another.
        let others = AppDelegate.shared.browsers.filter { $0.isPopup && $0 !== popup }.compactMap { $0.window?.frame.origin }
        while others.contains(where: { abs($0.x - frame.origin.x) < 1 && abs($0.y - frame.origin.y) < 1 }) {
            frame.origin.x += 24
            frame.origin.y -= 24
        }
        window.setFrame(frame, display: false)
        // Chromium puts the page that asked for the window in this view, opener and all.
        let view = SillWebView(forPopupWithFrame: popup.pageBounds, private: isPrivate)
        popup.addTab(url: nil, adopting: view, opener: tab)
        popup.showWindow(nil)
        return view
    }

    func closeRequested(_ tab: Tab) { closeNow(tab) }

    func promptsChanged(_ tab: Tab) { placePrompts() }

    func loadedUnseen(_ tab: Tab) {
        guard tab !== selected, tabs.contains(where: { $0 === tab }), let view = tab.webView else { return }
        drawAhead(view)
    }

    /// The tab in front, or the other half of its split.
    func isInFront(_ tab: Tab) -> Bool {
        tab === selected || (split?.contains(tab) == true && split?.contains(selected) == true)
    }

    /// The card of each page that has a question, top right of that page
    /// while it is in front (either half of a split), and off otherwise.
    func placePrompts() {
        for tab in tabs {
            guard let ask = tab.asking else {
                tab.card?.removeFromSuperview()
                tab.card = nil
                continue
            }
            guard isInFront(tab), let view = tab.webView, view.isShown else {
                tab.card?.removeFromSuperview()
                continue
            }
            let card = tab.card ?? SitePrompt()
            tab.card = card
            if card.ask !== ask { card.show(ask) { [weak tab] in tab?.answer($0) } }
            card.place(over: stage.convert(view.bounds, from: view), in: stage, down: madeFindBar?.isOpen == true ? 54 : 0)
        }
    }

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
        // Not the scroll wheel: a watcher on it runs in Sill for every
        // scroll event before the page gets it. A look ends when ⌥ is let go.
        peekWatch = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
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
        // On Chromium the page starts below the bar: field positions are the page's own.
        Autofill.offer(for: field, in: tab, webView: webView, top: 0)
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
    fileprivate func placePages(keep: SillWebView?) {
        guard let selected else { return }
        // A page's question goes where its page now is.
        defer { placePrompts() }
        if let keep { leaving = keep }
        // A page only drawing ahead (drawAhead) is under the page in front
        // and seen by no one. Aside before anything moves, unless it's the
        // one coming in: the page over it may be about to go into a split's
        // half, and it would be left on top of the pair.
        for case let page as SillWebView in pageHost.subviews where page.drawingAhead && page !== selected.webView {
            page.park()
        }
        if let split, split.contains(selected) {
            // As for one page below: the pair comes back under the page being left.
            let shown = selected.webView as? SillWebView
            let under = keep == nil && leaving?.superview !== pageHost
                && shown?.shownBefore == true && splitView.superview !== pageHost
                && pageHost.subviews.contains { Self.covers($0) }
            if !under {
                putAside(except: splitView, keep)
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
                    self.putAside(except: self.splitView, self.leaving)
                }
            }
            for (pane, tab) in [(splitView.leftPane, split.left), (splitView.rightPane, split.right)] {
                if let tab {
                    let view = tab.materialize()
                    pane.show(view)
                    view.shownBefore = true
                    view.cameIntoView()
                } else {
                    chooser.offer(tabs.filter { !split.contains($0) && self.split(of: $0) == nil })
                    pane.show(chooser)
                }
            }
            splitView.layoutSubtreeIfNeeded()
            splitView.apply(fraction: split.fraction)
        } else {
            let webView = selected.materialize()
            // One drawing ahead is in the page area but not yet in front.
            let placed = webView.superview === pageHost && !webView.isHidden && !webView.drawingAhead
            // A page that has been shown before comes back under the one
            // being left, which goes once the new one has drawn: nothing
            // waits, and the window never shows through between the two.
            let under = keep == nil && leaving?.superview !== pageHost
                && (webView.shownBefore || webView.laidOutUnseen || webView.drawingAhead) && !placed
                && !webView.isDescendant(of: splitView)
                && pageHost.subviews.contains { ($0 !== webView && Self.covers($0)) || $0 === splitView }
            if !under { putAside(except: webView, keep) }
            if webView.superview !== pageHost {
                webView.frame = pageHost.bounds
                pageHost.addSubview(webView, positioned: under ? .below : .above, relativeTo: nil)
                // Put aside hidden where it was before (another window, for
                // a tab dragged in): it stayed hidden here, a blank page.
                webView.isHidden = false
            } else if !placed || keep != nil {
                // Only hidden since it was last in front (see SillWebView.park),
                // or already here under a page kept for its video to float:
                // to the front either way.
                webView.frame = pageHost.bounds
                order(webView, below: under)
                webView.isHidden = false
            }
            webView.autoresizingMask = [.width, .height]
            webView.shownBefore = true
            webView.outgoing = false
            webView.cameIntoView()
            if under {
                for case let old as SillWebView in pageHost.subviews where old !== webView { old.outgoing = true }
                webView.afterNextFrame { [weak self, weak webView] in
                    guard let self, let webView, self.selected?.webView === webView,
                          webView.superview === self.pageHost, !webView.isHidden else { return }
                    self.putAside(except: webView, self.leaving)
                }
            }
        }
    }

    /// A page in the page area that is in sight: not put aside, and not one
    /// only drawing ahead under the others.
    private static func covers(_ view: NSView) -> Bool {
        // A page (a WKWebView on WebKit; on Chromium every page is a SillWebView).
        (view is SillWebView || view is WKWebView) && !view.isHidden && (view as? SillWebView)?.drawingAhead != true
            && (view as? SillWebView)?.floating != true
    }

    /// A page loaded out of sight (a tab next door, one opened behind, the
    /// palette's guess) goes into the page area under the page in front so
    /// that WebKit draws it (SillWebView.drawingAhead): shown later it's up
    /// in a frame or two, rather than after drawing from nothing. Only under
    /// one page that covers the whole area, fully in, in a window on screen.
    /// `live`: it stays, drawing as it loads (the palette's guess, until
    /// Return or the palette goes); else it's put aside once it has drawn.
    func drawAhead(_ view: SillWebView, live: Bool = false) {
        guard !view.drawingAhead, view.window == nil || view.superview === pageHost,
              let window, window.occlusionState.contains(.visible), let selected,
              split?.contains(selected) != true,
              let front = selected.webView, front !== view, front.superview === pageHost, front.isShown,
              front.isFullyIn
        else { return }
        view.startDrawingAhead()
        view.frame = pageHost.bounds
        view.autoresizingMask = [.width, .height]
        if view.superview === pageHost { order(view, below: true); view.isHidden = false }
        else { pageHost.addSubview(view, positioned: .below, relativeTo: nil) }
        guard !live else { return }
        // A heavy page takes a few hundred ms to draw the first time (apple.com 815 ms once).
        view.afterNextFrame(within: 1) { [weak view] in
            guard let view, view.drawingAhead else { return }
            view.park()
        }
    }

    /// Every page in the page area but these is hidden where it is; the
    /// split's two halves, which hold their own pages, leave the window.
    private func putAside(except shown: NSView?, _ kept: NSView?) {
        for view in pageHost.subviews where view !== shown && view !== kept {
            if let page = view as? SillWebView { page.park() } else { view.removeFromSuperview() }
        }
    }

    /// Moves a page already in the page area to the back or the front of it
    /// without taking it out of the window.
    private func order(_ view: NSView, below: Bool) {
        var context = (Unmanaged.passUnretained(view).toOpaque(), below)
        withUnsafeMutablePointer(to: &context) { pointer in
            pageHost.sortSubviews({ a, b, raw in
                let (target, below) = raw!.assumingMemoryBound(to: (UnsafeMutableRawPointer, Bool).self).pointee
                let isA = Unmanaged.passUnretained(a).toOpaque() == target, isB = Unmanaged.passUnretained(b).toOpaque() == target
                if isA == isB { return .orderedSame }
                return (isA == below) ? .orderedAscending : .orderedDescending
            }, context: pointer)
        }
    }

    /// Split Left / Split Right on a tab: it goes to that side. Another tab
    /// than the one you're on pairs with yours at once, yours on the other
    /// side; the tab you're on itself waits there while you pick its partner.
    func split(_ tab: Tab, onLeft: Bool) {
        // A tab is in one split at most: one already in another leaves it.
        if let current = selected, current !== tab, tabs.contains(where: { $0 === current }) {
            dissolveSplit(of: current)
            dissolveSplit(of: tab)
            pendingSplit = onLeft ? SplitPair(left: nil, right: current) : SplitPair(left: current, right: nil)
            fillSplit(with: tab)
            return
        }
        dissolveSplit(of: tab)
        pendingSplit = onLeft ? SplitPair(left: tab, right: nil) : SplitPair(left: nil, right: tab)
        showPairs()
        if selected === tab {
            placePages(keep: nil)
        } else {
            select(tab)
        }
    }

    fileprivate func fillSplit(with tab: Tab) {
        guard let pair = pendingSplit else { return }
        dissolveSplit(of: tab)
        if pair.left == nil { pair.left = tab } else { pair.right = tab }
        pendingSplit = nil
        splits.append(pair)
        // The pair sits together in the row, left then right, in one capsule.
        // The tab just picked moves beside the one already there, which stays put.
        if let left = pair.left, let right = pair.right,
           let l = tabs.firstIndex(where: { $0 === left }), let r = tabs.firstIndex(where: { $0 === right }), r != l + 1 {
            if tab === left {
                tabs.remove(at: l)
                tabs.insert(left, at: tabs.firstIndex(where: { $0 === right }) ?? r)
            } else {
                tabs.remove(at: r)
                tabs.insert(right, at: (tabs.firstIndex(where: { $0 === left }) ?? l) + 1)
            }
            strip.sync(animated: true)
        }
        select(tab)
        placePages(keep: nil)
        showPairs()
        changed()
    }

    /// Ends the split in front (or the one being made): its pages each go
    /// back to being a tab of their own.
    @objc func unsplit() {
        guard let pair = split else { return }
        unsplit(pair)
    }

    func unsplit(_ pair: SplitPair) {
        if pendingSplit === pair { pendingSplit = nil }
        splits.removeAll { $0 === pair }
        changed()
        showPairs()
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
        guard Preferences.shared.showsTabPreviews, !paletteOpen, !GlassMenu.isOpen,
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
    fileprivate func warmNeighbours(of tab: Tab, waited: TimeInterval = 0) {
        neighbourWarming?.cancel()
        let pause: TimeInterval = waited == 0 ? 1.0 : 0.5
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab, tab === self.selected, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            // Not while the page in front is still coming in: two more pages
            // loading beside it would share its network and processor, and
            // it's the one being looked at. A page that never settles doesn't
            // hold them off for more than a few seconds.
            if tab.isLoading, waited < 6 { return self.warmNeighbours(of: tab, waited: waited + pause) }
            // Each on a turn of its own: making a web view and starting its
            // load holds the main thread a few milliseconds, two in a row twice that.
            let neighbours = [index - 1, index + 1].filter { self.tabs.indices.contains($0) }.map { self.tabs[$0] }
            for (n, neighbour) in neighbours.enumerated() {
                let wake = { [weak self, weak neighbour, weak tab] in
                    guard let self, let neighbour, let tab, tab === self.selected,
                          neighbour.webView == nil, !neighbour.warmedUnseen else { return }
                    self.warm(neighbour)
                    neighbour.warmedUnseen = neighbour.webView != nil
                }
                if n == 0 { wake() } else { Frame.afterCommit(wake) }
            }
            // Once, with the first tab shown after a relaunch.
            if !self.warmAfterRestore.isEmpty {
                self.warmRecent(self.warmAfterRestore)
                self.warmAfterRestore = []
            }
        }
        neighbourWarming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
    }

    /// After a relaunch the tabs either side of the one in front aren't the
    /// only ones likely to be clicked: up to two more are loaded ahead, the
    /// ones looked at last before quitting, one at a time once nothing in
    /// the window is loading, and only while the Mac has 3 GB to spare. Each
    /// is a web process of 100 to 400 MB once loaded (measured: Wikipedia
    /// 111, apple.com 146, BBC News 402, the New York Times 441), and goes
    /// back to sleep, as any tab does, if it isn't looked at.
    private func warmRecent(_ candidates: [Tab], waited: TimeInterval = 0, warmed: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let left = candidates.filter { tab in tab.webView == nil && !tab.warmedUnseen && self.tabs.contains { $0 === tab } }
            guard warmed < 2, let next = left.first else { return }
            if self.tabs.contains(where: { $0.isLoading }) {
                guard waited < 20 else { return }
                return self.warmRecent(left, waited: waited + 1, warmed: warmed)
            }
            guard Self.memoryToSpare else { return }
            self.warm(next)
            next.warmedUnseen = next.webView != nil
            self.warmRecent(Array(left.dropFirst()), warmed: warmed + 1)
        }
    }

    /// Free, inactive and purgeable memory: what the Mac can give a page
    /// without pushing anything else out.
    private static var memoryToSpare: Bool {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return false }
        let pages = UInt64(info.free_count) + UInt64(info.inactive_count) + UInt64(info.purgeable_count)
        return pages * UInt64(getpagesize()) > 3 << 30
    }

    /// A click into the other half of a split makes that page the one in
    /// front: the address, back and forward and page commands follow it.
    func paneFocused(_ tab: Tab) {
        guard let split, split.contains(tab), selected !== tab, tabs.contains(where: { $0 === tab }) else { return }
        selected = tab
        tab.lastShown = Date()
        strip.select(tab)
        showPairs()
        window?.title = tab.displayTitle
        updateNavigation()
        changed()
    }
}
