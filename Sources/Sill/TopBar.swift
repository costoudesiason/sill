import AppKit
import UniformTypeIdentifiers

/// The bar across the top of the window, in place of an NSToolbar so its
/// margins are ours: back, forward and reload in one glass capsule hard by the left
/// edge, the tabs filling the middle, and Downloads, New Tab and Show All Tabs
/// in one glass capsule on the right. It sits on the window's glass, which
/// shows the desktop behind the window; the page starts below it.
final class TopBar: NSView {
    static let height: CGFloat = 52
    static let capsule: CGFloat = 36
    private static let margin: CGFloat = 8
    private static let buttonWidth: CGFloat = 37

    let strip: TabStripView
    private let navGlass = NSGlassEffectView()
    private let navContent = FlippedView()
    private let actionsGlass = NSGlassEffectView()
    private let actionsContent = FlippedView()
    private let divider = NSView()
    private let divider2 = NSView()
    /// Your profile: its own round glass at the right end of the bar.
    private let profileGlass = NSGlassEffectView()
    let profile = ProfileButton()

    let back = BarButton(symbol: "chevron.backward", label: "Back")
    let forward = BarButton(symbol: "chevron.forward", label: "Forward")
    let reload = BarButton(symbol: "arrow.clockwise", label: "Reload Page")
    let extensions = BarButton(symbol: "puzzlepiece.extension", label: "Extensions")
    let downloads = DownloadsButton()
    let add = BarButton(symbol: "plus", label: "New Tab")
    let allTabs = BarButton(symbol: "square.on.square", label: "Show All Tabs")

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// While the page loads the reload button stops it, as Safari's does.
    var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            reload.setSymbol(isLoading ? "xmark" : "arrow.clockwise", label: isLoading ? "Stop Loading" : "Reload Page")
        }
    }

    /// A popup's bar (a "Sign in with…" window): back, forward and its one
    /// page's title, none of the browser's own buttons or the profile.
    var isPopup = false {
        didSet {
            actionsGlass.isHidden = isPopup
            profileGlass.isHidden = isPopup
            needsLayout = true
        }
    }

    /// Files and links dropped on the bar: they open in new tabs, at the place
    /// among the tabs where they were let go (nil: after the last). Dropped
    /// on the page they stay the page's, for an upload.
    var onDrop: (([URL], Int?) -> Void)?

    /// Room kept on the left for the window's traffic lights.
    var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { needsLayout = true } } }

    init(strip: TabStripView) {
        self.strip = strip
        super.init(frame: .zero)

        profileGlass.effectIsInteractive = true
        profileGlass.cornerRadius = Self.capsule / 2
        profileGlass.contentView = profile
        for glass in [navGlass, actionsGlass] {
            glass.effectIsInteractive = true
            glass.cornerRadius = Self.capsule / 2
        }
        navGlass.contentView = navContent
        actionsGlass.contentView = actionsContent
        navContent.addSubview(back)
        navContent.addSubview(divider)
        navContent.addSubview(forward)
        navContent.addSubview(divider2)
        navContent.addSubview(reload)
        divider.wantsLayer = true
        divider2.wantsLayer = true
        actionsContent.addSubview(extensions)
        actionsContent.addSubview(downloads)
        actionsContent.addSubview(add)
        actionsContent.addSubview(allTabs)

        // Straight on the bar, not in a glass container spanning it: the
        // container was resized on every frame of a window resize and laid
        // its glass out again each time, some 1.5 of the 5.7 ms a frame cost
        // (median, a harness of this bar with 15 tabs), while the two
        // capsules, too far apart to ever merge, drew to the same pixels
        // without it, light and dark (captured and compared).
        addSubview(navGlass)
        addSubview(actionsGlass)
        addSubview(profileGlass)
        addSubview(strip)
        strip.translatesAutoresizingMaskIntoConstraints = true
        registerForDraggedTypes([.fileURL, .URL])

        back.toolTip = "Back"
        forward.toolTip = "Forward"
        reload.toolTip = "Reload Page"
        extensions.toolTip = "Extensions"
        downloads.toolTip = "Downloads"
        add.toolTip = "New Tab"
        allTabs.toolTip = "Show All Tabs"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let c = Self.capsule
        let y = (h - c) / 2
        let w = Self.buttonWidth

        navGlass.frame = NSRect(x: Self.margin + leadingInset, y: y, width: w * 3, height: c)
        navContent.frame = navGlass.bounds
        back.frame = NSRect(x: 0, y: 0, width: w, height: c)
        forward.frame = NSRect(x: w, y: 0, width: w, height: c)
        reload.frame = NSRect(x: w * 2, y: 0, width: w, height: c)
        divider.frame = NSRect(x: w - 0.5, y: 9, width: 1, height: c - 18)
        divider2.frame = NSRect(x: w * 2 - 0.5, y: 9, width: 1, height: c - 18)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
            divider2.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }

        profileGlass.frame = NSRect(x: bounds.width - Self.margin - c, y: y, width: c, height: c)
        profile.frame = profileGlass.bounds
        let actionsWidth = w * 4
        actionsGlass.frame = NSRect(x: profileGlass.frame.minX - 8 - actionsWidth, y: y, width: actionsWidth, height: c)
        actionsContent.frame = actionsGlass.bounds
        extensions.frame = NSRect(x: 0, y: 0, width: w, height: c)
        downloads.frame = NSRect(x: w, y: 0, width: w, height: c)
        add.frame = NSRect(x: w * 2, y: 0, width: w, height: c)
        allTabs.frame = NSRect(x: w * 3, y: 0, width: w, height: c)

        let stripX = navGlass.frame.maxX + 8
        let stripEnd = isPopup ? bounds.width - Self.margin : actionsGlass.frame.minX - 8
        strip.frame = NSRect(x: stripX, y: y, width: max(0, stripEnd - stripX), height: c)
    }

    /// Where the Downloads button is, in the bar's own coordinates: what a
    /// popover anchors to (a view inside glass reports its place unreliably
    /// while the glass lifts it).
    var downloadsRect: NSRect {
        NSRect(x: actionsGlass.frame.minX + Self.buttonWidth, y: actionsGlass.frame.minY, width: Self.buttonWidth, height: Self.capsule)
    }
    var extensionsRect: NSRect {
        NSRect(x: actionsGlass.frame.minX, y: actionsGlass.frame.minY, width: Self.buttonWidth, height: Self.capsule)
    }
    var profileRect: NSRect { profileGlass.frame }

    // MARK: - dropping files and links

    /// What a drag carries that a tab can show: web addresses, and files
    /// Chromium displays (PDFs, pictures, pages, text, audio and video),
    /// never a folder or an app, which would only download.
    private static func openable(_ info: NSDraggingInfo) -> [URL] {
        let board = info.draggingPasteboard
        let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        let shown: [UTType] = [.pdf, .image, .html, .xml, .text, .json, .audiovisualContent, .webArchive]
        return urls.filter { url in
            if url.isFileURL {
                guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
                return shown.contains { type.conforms(to: $0) }
            }
            return url.scheme == "http" || url.scheme == "https"
        }
    }

    // A copy, so the pointer wears the green plus: this opens it, it doesn't move it.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDrop != nil && !Self.openable(sender).isEmpty ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.openable(sender)
        guard let onDrop, !urls.isEmpty else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let index = strip.frame.contains(point) ? strip.dropIndex(at: strip.convert(point, from: self).x) : nil
        onDrop(urls, index)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // A double-click on bare bar does what it does on any title bar.
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        // Bare bar: the window moves with the pointer, as a title bar's does.
        window?.performDrag(with: event)
    }
}

/// A symbol button on the bar's glass: borderless, the glass gives the press.
class BarButton: NSButton {
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .accessoryBarAction
        setSymbol(symbol, label: label)
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        setAccessibilityLabel(label)
        setButtonType(.momentaryChange)
        wantsLayer = true
        hover.opacity = 0
        hover.actions = ["bounds": NSNull(), "position": NSNull(), "cornerRadius": NSNull()]
        layer?.insertSublayer(hover, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        toolTip = toolTip == nil ? nil : label
        setAccessibilityLabel(label)
    }

    /// Under the pointer: a soft pill, inset evenly from the capsule's edge
    /// so its ends follow the capsule's curve.
    private let hover = CALayer()
    private var tracking: NSTrackingArea?

    override func layout() {
        super.layout()
        let inset: CGFloat = 3
        let rect = bounds.insetBy(dx: inset, dy: inset)
        hover.frame = rect
        hover.cornerRadius = rect.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hover.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { showHover(isEnabled) }
    override func mouseExited(with event: NSEvent) { showHover(false) }

    private func showHover(_ on: Bool) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = hover.presentation()?.opacity ?? hover.opacity
        animation.duration = on ? 0.12 : 0.2
        hover.opacity = on ? 1 : 0
        hover.add(animation, forKey: "opacity")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Set on every tab switch and back/forward change: redrawn only when it changes.
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor
            if !isEnabled { hover.opacity = 0 }
        }
    }
}

/// Downloads: while files come down, its symbol's circle becomes a ring
/// that fills with them, the arrow inside. When the last one lands the ring
/// closes and fades, the circle comes back, and the arrow gives a bounce.
final class DownloadsButton: BarButton {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let glyph = NSImageView()
    private var showing: Downloads.Overall?
    private var settling: DispatchWorkItem?

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "Downloads")?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
    private static let idle = symbol("arrow.down.circle", size: 16, weight: .regular)
    private static let busy = symbol("arrow.down", size: 9, weight: .bold)

    init() {
        super.init(symbol: "arrow.down.circle", label: "Downloads")
        image = nil
        glyph.image = Self.idle
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = .labelColor
        addSubview(glyph)
        for ring in [track, fill] {
            ring.fillColor = nil
            ring.lineWidth = 1.5
            ring.opacity = 0
            ring.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "strokeColor": NSNull()]
            layer?.addSublayer(ring)
        }
        fill.lineCap = .round
        fill.strokeEnd = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    // The glyph is only a picture: the press is the button's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        glyph.frame = bounds
        // The ring sits where the symbol's own circle does.
        let path = CGMutablePath()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // The button's layer is flipped (y down): from the top, round clockwise.
        path.addArc(center: center, radius: 7.3, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        for ring in [track, fill] {
            ring.frame = bounds
            ring.path = path
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.2).cgColor
            fill.strokeColor = NSColor.controlAccentColor.cgColor
        }
    }

    /// How the downloads are going: nil when nothing is coming down.
    func show(_ progress: Downloads.Overall?, animated: Bool = true) {
        guard progress != showing else { return }
        let was = showing
        showing = progress
        let moving = animated && !Motion.reduced
        if let progress {
            settling?.cancel()
            settling = nil
            if was == nil || glyph.image !== Self.busy {
                swap(to: Self.busy, animated: moving)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                fill.strokeEnd = 0
                CATransaction.commit()
                fade(rings: 1, animated: moving)
            }
            setAccessibilityValue(progress.fraction.map { "\(Int($0 * 100)) percent" } ?? "Downloading")
            if let fraction = progress.fraction {
                fill.removeAnimation(forKey: "spin")
                CATransaction.begin()
                CATransaction.setAnimationDuration(moving ? 0.3 : 0)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
                fill.strokeEnd = max(0.03, fraction)
                CATransaction.commit()
            } else {
                // No size known: a quarter of the ring, going round.
                fill.strokeEnd = 0.25
                spinIfUnsized()
            }
        } else {
            setAccessibilityValue(nil)
            guard was != nil else { return }
            // The ring closes, then gives way to the circle.
            fill.removeAnimation(forKey: "spin")
            CATransaction.begin()
            CATransaction.setAnimationDuration(moving ? 0.2 : 0)
            fill.strokeEnd = 1
            CATransaction.commit()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.settling = nil
                self.fade(rings: 0, animated: moving)
                self.swap(to: Self.idle, animated: moving)
                if moving { self.glyph.addSymbolEffect(.bounce, options: .nonRepeating) }
            }
            settling = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (moving ? 0.35 : 0), execute: work)
        }
    }

    /// The quarter ring of a download of unknown size goes round, whether
    /// the window was opened before or during it, and again after the
    /// layer has left the window (which takes its animations with it).
    private func spinIfUnsized() {
        guard let showing, showing.fraction == nil, !Motion.reduced, fill.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1
        spin.repeatCount = .infinity
        fill.add(spin, forKey: "spin")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { spinIfUnsized() }
    }

    private func swap(to image: NSImage?, animated: Bool) {
        guard let image else { return }
        if animated { glyph.setSymbolImage(image, contentTransition: .replace) } else { glyph.image = image }
    }

    private func fade(rings opacity: Float, animated: Bool) {
        for ring in [track, fill] {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = ring.presentation()?.opacity ?? ring.opacity
            animation.duration = animated ? 0.2 : 0
            ring.opacity = opacity
            ring.add(animation, forKey: "opacity")
        }
    }
}

/// The profile button: your Mac account's picture, round, filling the
/// glass; your initials where there is no picture.
final class ProfileButton: NSButton {
    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .accessoryBarAction
        imagePosition = .imageOnly
        // Smaller than its glass, centred, so the glass shows around it as
        // it does around the bar's other buttons.
        imageScaling = .scaleNone
        toolTip = Profile.name
        setAccessibilityLabel("Profile, \(Profile.name)")
        // Your picture once it's been looked up (usually before the window
        // shows); never your initials first and then a swap.
        Profile.whenReady { [weak self] in
            guard let self, !self.isPrivate else { return }
            self.image = Profile.picture(size: 26)
        }
    }
    private var isPrivate = false
    required init?(coder: NSCoder) { fatalError() }

    /// A private window says so where your picture would be, with Safari's
    /// raised hand: dark like any dark window, it was otherwise no
    /// different to look at.
    func markPrivate() {
        isPrivate = true
        image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Private Window")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        contentTintColor = .labelColor
        toolTip = "Private Window"
        setAccessibilityLabel("Private Window")
    }
}
