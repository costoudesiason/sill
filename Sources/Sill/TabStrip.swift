import AppKit

/// The row of tabs in the bar. Tabs share the width (all of it, or up to a
/// comfortable maximum), sit straight on the bar, and the one in front is a
/// selection fill: a state, not another layer of glass (macOS 27's own
/// segmented tabs work the same way). Motion is geometry, as in Apple's tab
/// bars: a new tab grows out of its slot while its neighbours make room, a
/// closed one collapses while they close the gap, both laid out at full width
/// inside and clipped, so nothing reflows mid-flight. Switching is instant.
/// Closing with the mouse holds the widths until the pointer leaves, so the
/// next close button lands under it. Reduce Motion makes every change a cut.
final class TabStripView: NSView {
    weak var browser: BrowserWindowController?

    static let height: CGFloat = 36
    private let minWidth: CGFloat = 40
    private let spacing: CGFloat = 4
    /// Opening, closing and making room: quick, eased out, no bounce.
    static let reflow: TimeInterval = 0.24
    private var maxWidth: CGFloat { Preferences.shared.tabWidth == .fill ? .greatestFiniteMagnitude : 300 }

    private(set) var items: [TabItemView] = []
    private var heldWidth: CGFloat?
    private var dragged: TabItemView?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var animates: Bool { !Motion.reduced }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard heldWidth != nil else { return }
        heldWidth = nil
        layoutItems(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        // Bare bar: the window moves with the pointer, as a title bar's does.
        window?.performDrag(with: event)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        // A window resize lays tabs out at once; only tab changes animate.
        if dragged == nil { layoutItems(animated: false) }
    }

    // MARK: - keeping up with the tabs

    /// Brings the views in line with the window's tabs.
    func sync(animated: Bool) {
        guard let browser else { return }
        let animated = animated && animates
        let ids = Set(browser.tabs.map(\.id))

        // Going: collapse to nothing where they stand, still laid out at
        // their old width inside, while the rest close the gap.
        let leaving = items.filter { !ids.contains($0.tab.id) }
        items.removeAll { !ids.contains($0.tab.id) }

        // A new tile is filled in as it's made, a tile whose tab changed was
        // refreshed when it did (refresh(_:)), and a change of front restyles
        // itself: nothing else needs redoing here.
        let existing = Dictionary(uniqueKeysWithValues: items.map { (ObjectIdentifier($0.tab), $0) })
        var fresh: [TabItemView] = []
        items = browser.tabs.map { tab in
            if let item = existing[ObjectIdentifier(tab)] { return item }
            let item = TabItemView(tab: tab, strip: self)
            addSubview(item)
            fresh.append(item)
            return item
        }
        for item in items { item.isFront = item.tab === browser.selected }

        let frames = targetFrames()
        // Coming: start as a sliver at the left edge of its slot.
        Motion.still {
            for item in fresh {
                guard let target = frames[ObjectIdentifier(item)] else { continue }
                if animated {
                    item.layoutWidth = target.width
                    item.frame = NSRect(x: target.minX, y: target.minY, width: 0, height: target.height)
                } else {
                    item.frame = target
                }
            }
        }

        guard animated else {
            leaving.forEach { $0.removeFromSuperview() }
            layoutItems(animated: false, frames: frames)
            return
        }
        for item in leaving {
            // It goes under its neighbours and fades as it folds away, so the
            // tab sliding into its place never shows through it, doubled.
            item.layoutWidth = item.frame.width
            item.isLeaving = true
            item.isFront = false
            item.isPaired = false
            item.layer?.zPosition = -1
        }
        // Gone from sight in half the time: tabs have no fill of their own,
        // so a neighbour growing across one shows both through each other
        // (its icon over their titles, captured) for as long as it lingers.
        if !leaving.isEmpty {
            Motion.animate(Self.reflow / 2) { for item in leaving { item.animator().alphaValue = 0 } }
        }
        Motion.animate(Self.reflow, {
            for item in leaving {
                item.animator().frame = NSRect(x: item.frame.minX, y: item.frame.minY, width: 0, height: item.frame.height)
            }
            for item in items where item !== dragged {
                if let target = frames[ObjectIdentifier(item)] { item.animator().frame = target }
            }
        }, completion: {
            leaving.forEach { $0.removeFromSuperview() }
            fresh.forEach { $0.layoutWidth = nil }
        })
        placeBackdrop(animated: true, frames: frames)
    }

    func refresh(_ tab: Tab) {
        items.first { $0.tab === tab }?.refresh()
    }

    /// Selection is a state: it changes at once, as in any Mac list.
    func select(_ tab: Tab?) {
        for item in items { item.isFront = item.tab === tab }
        if pair != nil { placeBackdrop(animated: false) }
    }

    /// Whether the tiles are the window's tabs, in order: then a new
    /// selection is all that changed, and select(_:) is enough.
    func matches(_ tabs: [Tab]) -> Bool {
        items.count == tabs.count && zip(items, tabs).allSatisfy { $0.tab === $1 }
    }

    /// Two tabs side by side in a split share one capsule in the row, so
    /// the pair reads as one, whichever tab is in front.
    private var pair: (Tab, Tab)?
    private lazy var pairBackdrop: NSView = {
        let view = PairBackdrop()
        addSubview(view, positioned: .below, relativeTo: nil)
        return view
    }()

    func showPair(_ left: Tab?, _ right: Tab?) {
        if let left, let right { pair = (left, right) } else { pair = nil }
        placeBackdrop(animated: true)
    }

    private func placeBackdrop(animated: Bool, frames: [ObjectIdentifier: NSRect]? = nil) {
        let paired = pairedItems()
        // The pair's capsule is the highlight of both its tabs: neither draws
        // a fill of its own, hovered or not, which at the tab's full height
        // showed the thinner capsule's edge through it.
        for item in items { item.isPaired = paired.map { item === $0.0 || item === $0.1 } ?? false }
        guard let (a, b) = paired else {
            stopFollowing()
            if !pairBackdrop.isHidden { pairBackdrop.isHidden = true }
            return
        }
        let wasHidden = pairBackdrop.isHidden
        // While either tab is moving (a tab opened or closed beside them, a
        // reorder, a resize of the row) the capsule follows where they are
        // on screen, frame by frame, until they stop: its shape, cut where the
        // front tab is, can't be animated between two cuts that differ.
        if animated, animates, !wasHidden {
            followFrom = CACurrentMediaTime()
            followUntil = followFrom + Self.reflow + 0.05
            if backdropLink == nil {
                let link = displayLink(target: self, selector: #selector(followBackdrop))
                link.add(to: .main, forMode: .common)
                backdropLink = link
            }
            followBackdrop()
            return
        }
        guard backdropLink == nil else { return }   // already following; it reads the latest state
        let frames = frames ?? targetFrames()
        guard let fa = frames[ObjectIdentifier(a)], let fb = frames[ObjectIdentifier(b)] else { return }
        shapeBackdrop(a: a, fa: fa, b: b, fb: fb)
    }

    /// The pair's two tiles, if they sit side by side.
    private func pairedItems() -> (TabItemView, TabItemView)? {
        guard let pair,
              let a = items.first(where: { $0.tab === pair.0 }), let b = items.first(where: { $0.tab === pair.1 }),
              let ia = items.firstIndex(of: a), let ib = items.firstIndex(of: b), abs(ia - ib) == 1 else { return nil }
        return (a, b)
    }

    private func isMoving(_ item: TabItemView) -> Bool {
        !(item.layer?.animationKeys() ?? []).isEmpty
    }

    private var backdropLink: CADisplayLink?
    private var followFrom: CFTimeInterval = 0
    private var followUntil: CFTimeInterval = 0

    @objc private func followBackdrop() {
        guard let (a, b) = pairedItems(), dragged == nil else { return stopFollowing() }
        let fa = a.layer?.presentation()?.frame ?? a.frame
        let fb = b.layer?.presentation()?.frame ?? b.frame
        shapeBackdrop(a: a, fa: NSRect(x: fa.minX, y: a.frame.minY, width: fa.width, height: a.frame.height),
                      b: b, fb: NSRect(x: fb.minX, y: b.frame.minY, width: fb.width, height: b.frame.height))
        // Done once they've stopped (given a frame or two for a move just
        // begun to show), and in any case after the row's animation.
        let now = CACurrentMediaTime()
        let still = !isMoving(a) && !isMoving(b)
        if now > followUntil || (still && now > followFrom + 0.04) {
            stopFollowing()
            placeBackdrop(animated: false)   // exactly where they settled
        }
    }

    private func stopFollowing() {
        backdropLink?.invalidate()
        backdropLink = nil
    }

    /// The two tabs' span, a tad thinner than them all round, so the front
    /// tab's glass stands a little proud of it, concentric; and cut where
    /// that tab is, since its glass is see-through.
    private func shapeBackdrop(a: TabItemView, fa: NSRect, b: TabItemView, fb: NSRect) {
        let target = fa.union(fb).insetBy(dx: 3, dy: 3)
        let front = a.isFront ? fa : b.isFront ? fb : nil
        let hole = front.map { $0.offsetBy(dx: -target.minX, dy: -target.minY) }
        let backdrop = pairBackdrop as! PairBackdrop
        backdrop.isHidden = false
        Motion.still { backdrop.frame = target }
        backdrop.shape(size: target.size, hole: hole)
    }

    func prefsChanged() {
        items.forEach { $0.refresh() }
        layoutItems(animated: true)
    }

    // MARK: - layout

    private func width(for count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let even = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return floor(min(maxWidth, max(minWidth, even)))
    }

    /// Where the row starts: tabs as wide as they may be, and the row in
    /// the middle of the bar when they don't fill it; more tabs, narrower
    /// tabs, until they do.
    private func rowStart(tabWidth: CGFloat) -> CGFloat {
        let count = CGFloat(items.count)
        guard count > 0, heldWidth == nil else { return heldStart }
        let row = count * tabWidth + (count - 1) * spacing
        return max(0, floor((bounds.width - row) / 2))
    }
    private var heldStart: CGFloat = 0

    private func targetFrames() -> [ObjectIdentifier: NSRect] {
        let tabWidth = heldWidth ?? width(for: items.count)
        var result: [ObjectIdentifier: NSRect] = [:]
        var x: CGFloat = rowStart(tabWidth: tabWidth)
        for item in items {
            result[ObjectIdentifier(item)] = NSRect(x: x, y: 0, width: tabWidth, height: bounds.height)
            x += tabWidth + spacing
        }
        return result
    }

    func layoutItems(animated: Bool, frames: [ObjectIdentifier: NSRect]? = nil) {
        let frames = frames ?? targetFrames()
        let apply = {
            for item in self.items where item !== self.dragged {
                guard let target = frames[ObjectIdentifier(item)] else { continue }
                if animated { item.animator().frame = target } else { item.frame = target }
            }
        }
        if animated && animates { Motion.animate(Self.reflow, apply) } else { Motion.still(apply) }
        if dragged == nil { placeBackdrop(animated: animated, frames: frames) }
    }

    private func slot(at x: CGFloat) -> Int {
        let tabWidth = items.first?.frame.width ?? width(for: items.count)
        let start = items.first?.frame.minX ?? 0
        let index = Int(((x - start) / (tabWidth + spacing)).rounded(.down))
        return max(0, min(items.count - 1, index))
    }

    // MARK: - from the tabs

    func close(_ item: TabItemView) {
        // Hold the widths (unless it's the last tab) so the next close button
        // slides under the pointer, as long as the pointer stays in the strip.
        if item !== items.last { heldWidth = item.frame.width; heldStart = items.first?.frame.minX ?? 0 }
        browser?.close(item.tab)
    }

    /// Follows the pointer from a mouse-down on a tab until it's let go.
    func track(_ item: TabItemView, from event: NSEvent) {
        guard let window else { return }
        browser?.hidePreview(animated: false)
        let wasFront = item.tab === browser?.selected
        if !wasFront { browser?.select(item.tab) }
        let start = convert(event.locationInWindow, from: nil)
        let grab = start.x - item.frame.minX
        var moved = false
        // Where it was in the row when grabbed: its place follows from how far
        // it has been dragged since, and nothing else.
        let firstIndex = items.firstIndex(of: item) ?? 0
        let firstSlot = targetFrames()[ObjectIdentifier(item)]?.minX ?? item.frame.minX

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            if !moved {
                guard abs(point.x - start.x) > 4 else { continue }
                moved = true
                dragged = item
                // Above its neighbours (a glass tab ignores a layer's z-position).
                addSubview(item, positioned: .above, relativeTo: nil)
                pairBackdrop.isHidden = true
            }
            // The tab stays under the pointer, along the row, no further than its ends.
            let x = max(0, min(bounds.width - item.frame.width, point.x - grab))
            Motion.still { item.setFrameOrigin(NSPoint(x: x, y: 0)) }
            // It takes a neighbour's place once it's halfway into that
            // neighbour's slot, and never needs more than 110 points of drag
            // for it: full-bar tabs are hundreds of points wide, and waiting
            // for its middle to pass the neighbour's (as it once did) meant
            // dragging a whole tab's width. Worked out from the distance
            // dragged since the tab was grabbed, so it never flickers back
            // and forth at the point it changes.
            guard let index = items.firstIndex(of: item) else { continue }
            let step = item.frame.width + spacing
            let threshold = min(step / 2, 110)
            let distance = x - firstSlot
            var places = 0
            if abs(distance) >= threshold { places = (Int(((abs(distance) - threshold) / step).rounded(.down)) + 1) * (distance < 0 ? -1 : 1) }
            let target = max(0, min(items.count - 1, firstIndex + places))
            if target != index {
                items.remove(at: index)
                items.insert(item, at: target)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                layoutItems(animated: true)
            }
        }

        guard moved else {
            // A click on the tab in front edits its address.
            if wasFront { browser?.showPalette(.address) }
            return
        }
        dragged = nil
        if let index = items.firstIndex(of: item) { browser?.move(item.tab, to: index) }
        // Settles into its slot, then drops back to the row's level.
        if let target = targetFrames()[ObjectIdentifier(item)] {
            Motion.animate(0.18, { item.animator().frame = target }, completion: { [weak self] in self?.placeBackdrop(animated: false) })
        }
    }
}

// MARK: - A tab

final class TabItemView: NSView {
    let tab: Tab
    private weak var strip: TabStripView?
    var isLeaving = false
    /// While a tab grows in or collapses out, its contents stay laid out at
    /// this width and `content` clips them to the frame.
    var layoutWidth: CGFloat? { didSet { if layoutWidth != oldValue { Motion.still { layoutContents() } } } }
    var isPaired = false { didSet { if isPaired != oldValue { needsDisplay = true } } }
    var isFront = false { didSet { if isFront != oldValue { wearGlass(isFront); clips(); restyle() } } }
    /// Six dots after the icon while an agent works in the tab (AgentActivity).
    var agentDots: NSView? {
        didSet {
            guard agentDots !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let agentDots { content.addSubview(agentDots) }
            needsLayout = true
        }
    }

    /// Rounded and clipped only while wearing glass. A rounded clip renders
    /// the tab offscreen each time the row is drawn, and a row of them made
    /// every frame of a tab opening or closing cost a pass per tab. The
    /// others' fill rounds itself, and their contents are kept inside them
    /// by `content`'s square clip, which costs no pass of its own: without
    /// it a title laid out at a tab's new width ran over its neighbours
    /// while the row grew (captured slowed down, Close Other Tabs in Fill).
    private func clips() {
        let clip = isFront
        if layer?.masksToBounds != clip { layer?.masksToBounds = clip }
    }

    /// The glass stays in the tab once made, hidden while the tab isn't in
    /// front: putting a glass view into the window and taking it out again
    /// on every switch cost some 5 ms a switch on the main thread, hiding
    /// and showing it 1.4 (a 30-tab harness, display and commit included).
    private func wearGlass(_ on: Bool) {
        Motion.still {
            if on {
                let glass = self.glass ?? makeGlass()
                content.removeFromSuperview()
                glass.frame = bounds
                glass.cornerRadius = bounds.height / 2
                glass.contentView = content
                content.frame = glass.bounds
                glass.isHidden = false
            } else if let glass {
                glass.isHidden = true
                glass.contentView = nil
                content.frame = bounds
                addSubview(content)
            }
        }
    }

    /// Only for a tab that comes to the front: a glass view takes some
    /// 0.4 ms to make, and a restored window of tabs made one for each.
    private func makeGlass() -> NSGlassEffectView {
        let made = NSGlassEffectView()
        made.effectIsInteractive = true
        addSubview(made, positioned: .below, relativeTo: nil)
        glass = made
        return made
    }
    private var isHovered = false { didSet { if isHovered != oldValue { restyle() } } }

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = TabCloseButton()
    private let fade = CAGradientLayer()
    /// The title's size, measured once per title and font: a label asked
    /// measures its text again each time, and every tab is laid out on every
    /// frame of a window resize.
    private var measured: (title: String, font: NSFont?, size: NSSize)?
    private var titleSize: NSSize {
        if let measured, measured.title == label.stringValue, measured.font == label.font { return measured.size }
        let size = label.intrinsicContentSize
        measured = (label.stringValue, label.font, size)
        return size
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click anywhere on the tab is the tab's (its close button aside):
    /// its label and glass are see-through views, which AppKit lets drag
    /// the window, so dragging a tab dragged the window with it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.contains(closeButton.superview.map { convert(local, to: $0) } ?? local) {
            return closeButton
        }
        return self
    }

    /// The tab in front is a piece of Liquid Glass. Its title and icon live
    /// inside the glass's own content view (a glass view only promises that
    /// view sits inside it; anything beside it gets refracted), so they move
    /// in when the tab comes to the front and out when it leaves.
    private var glass: NSGlassEffectView?
    private let content = FlippedView()

    init(tab: Tab, strip: TabStripView) {
        self.tab = tab
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        addSubview(content)

        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        label.font = Self.font
        label.lineBreakMode = .byClipping
        label.cell?.truncatesLastVisibleLine = false
        label.wantsLayer = true
        label.maximumNumberOfLines = 1
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        content.addSubview(label)

        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        closeButton.setAccessibilityLabel("Close Tab")
        content.addSubview(closeButton)

        setAccessibilityRole(.radioButton)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private var warming: DispatchWorkItem?

    override func mouseEntered(with event: NSEvent) {
        // Passing over tabs while dragging one isn't pointing at them.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        isHovered = true
        needsLayout = true
        // A moment's pause over a sleeping tab starts loading it, so it's ready
        // by the time it's clicked.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isHovered else { return }
            self.strip?.browser?.warm(self.tab)
        }
        warming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        strip?.browser?.tabHovered(tab, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        warming?.cancel()
        strip?.browser?.tabUnhovered(tab)
        needsLayout = true
    }

    // MARK: content

    /// The icon a page without one of its own gets: made once, not per refresh.
    private static let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    private static let font = NSFont.systemFont(ofSize: 13)
    private static let frontFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let privateIcon = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))

    /// Called for every load starting and ending, every new icon and title,
    /// of every tab: only what changed is set. A label given its text again,
    /// even the same, is measured again; a tooltip set again is re-added.
    func refresh() {
        let title = tab.displayTitle
        if label.stringValue != title {
            label.stringValue = title
            setAccessibilityLabel(title)
        }
        // The preview card says the same and more; a tooltip would sit on it.
        let tip = Preferences.shared.showsTabPreviews ? nil
            : tab.url.map { "\(title)\n\(Address.display($0))" } ?? title
        if toolTip != tip { toolTip = tip }
        let spinning = tab.isLoading && tab.favicon == nil
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        icon.isHidden = spinning
        let image = tab.favicon ?? (tab.isPrivate ? Self.privateIcon : Self.globe)
        if icon.image !== image { icon.image = image }
        let tint: NSColor? = tab.favicon == nil ? .secondaryLabelColor : nil
        if icon.contentTintColor != tint { icon.contentTintColor = tint }
        restyle()
    }

    private func restyle() {
        let color: NSColor = isFront ? .labelColor : .secondaryLabelColor
        if label.textColor != color { label.textColor = color }
        let font = isFront ? Self.frontFont : Self.font
        if label.font != font { label.font = font }
        setAccessibilityValue(isFront)
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            if isFront {
                color = .clear   // the glass is the selection
            } else if isPaired {
                // The pair's capsule is its highlight: a fill of its own, the
                // tab's full height, showed the thinner capsule's edge through it.
                color = .clear
            } else if isHovered {
                color = NSColor.labelColor.withAlphaComponent(0.06)
            } else {
                color = .clear
            }
            layer.backgroundColor = color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Laid out as the frame changes. The glass and the clip travel with the
    /// frame, inside whatever animation changes it; what's in them takes its
    /// new place at once and is uncovered as the tab grows (see layoutContents).
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutContents()
    }

    override func layout() {
        super.layout()
        Motion.still { layoutContents() }
    }

    private func layoutContents() {
        if let glass, !glass.isHidden {
            glass.frame = bounds
            glass.cornerRadius = bounds.height / 2
            content.frame = glass.bounds
        } else {
            content.frame = bounds
        }
        // In a resize of the row (a tab closing, the row reflowing) the icon,
        // title and close button travel with the tab, as its glass does: with
        // the title centred, put straight where they'd end up they lurched
        // sideways while the tab was still growing. The title's width alone
        // changes at once (a text field's frame doesn't travel). Otherwise,
        // straight there.
        let w = layoutWidth ?? bounds.width
        let context = NSAnimationContext.current
        if context.allowsImplicitAnimation, context.duration > 0, layoutWidth == nil {
            placeContents(width: w, narrow: w < 64, travelling: true)
        } else {
            Motion.still { placeContents(width: w, narrow: w < 64) }
        }
    }

    private func placeContents(width w: CGFloat, narrow: Bool, travelling: Bool = false) {
        let h = bounds.height
        let showsClose = isFront ? w >= 44 : ((isHovered || Preferences.shared.closeButtons == .always) && !narrow)
        closeButton.isHidden = !showsClose
        let iconSize: CGFloat = 16

        if narrow {
            // Just the icon, centred; the tab in front swaps it for its close button.
            let showIcon = !showsClose
            icon.isHidden = !showIcon || (tab.isLoading && tab.favicon == nil)
            icon.frame = NSRect(x: (w - iconSize) / 2, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
            spinner.frame = icon.frame
            closeButton.frame = NSRect(x: (w - 18) / 2, y: (h - 18) / 2, width: 18, height: 18)
            label.isHidden = true
            agentDots?.isHidden = true
            return
        }
        icon.isHidden = tab.isLoading && tab.favicon == nil
        label.isHidden = false
        // Icon and title together, in the middle of the tab, as Safari has
        // them; a title too long for it starts at the left and fades out.
        // The same margin both sides, so the close button coming and going
        // on hover doesn't move them.
        let margin: CGFloat = 34, gap: CGFloat = 8
        // A few points to spare: measured to the exact width, the title sat
        // a fraction over its field and the fade took its last letter.
        let dots: CGFloat = agentDots == nil ? 0 : 13   // the dots, and a gap before the title
        let group = min(w - margin * 2, iconSize + gap + dots + ceil(titleSize.width) + 6)
        let start = max(14, floor((w - group) / 2))
        icon.frame = NSRect(x: start, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        spinner.frame = icon.frame
        // Its centre as far from the right edge as the icon's is from the left.
        closeButton.frame = NSRect(x: w - 32, y: (h - 20) / 2, width: 20, height: 20)
        if let agentDots {
            agentDots.isHidden = false
            agentDots.frame = NSRect(x: start + iconSize + 6, y: (h - 12) / 2, width: 8, height: 12)
        }
        let labelX = start + iconSize + gap + dots
        let labelRight = min(showsClose ? w - margin : w - 14, max(labelX, start + group))
        let labelHeight = ceil(titleSize.height)
        let labelFrame = NSRect(x: labelX, y: (h - labelHeight) / 2, width: max(0, labelRight - labelX), height: labelHeight)
        if travelling {
            Motion.still { label.setFrameSize(labelFrame.size) }
            label.setFrameOrigin(labelFrame.origin)
        } else {
            label.frame = labelFrame
        }

        // Long titles fade out rather than end in an ellipsis.
        if titleSize.width > label.frame.width + 1, label.frame.width > 20 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fade.frame = label.bounds
            let start = max(0, (label.frame.width - 18) / label.frame.width)
            fade.locations = [0, NSNumber(value: start), 1]
            if label.layer?.mask !== fade { label.layer?.mask = fade }
            CATransaction.commit()
        } else if label.layer?.mask != nil {
            label.layer?.mask = nil
        }
        // No longer kept as a bitmap while masked: inside the glass that
        // bitmap came out a few letters wide ("GitHu", captured), and a
        // trace of 15 tabs opening and closing (Instruments, Animation
        // Hitches) found the row's frames as quick without it, with no
        // offscreen passes either way.
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        guard !isLeaving else { return }
        strip?.track(self, from: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { strip?.close(self) } else { super.otherMouseDown(with: event) }
    }

    /// Right-click: the tab's commands in a glass menu at the pointer.
    override func rightMouseDown(with event: NSEvent) {
        guard let browser = strip?.browser, let window, GlassMenu.shouldOpen(from: self) else { return }
        let menu = browser.menu(for: tab)
        let entries = GlassMenu.entries(from: menu, symbols: [
            "New Tab": "plus", "Reload": "arrow.clockwise", "Duplicate": "plus.square.on.square",
            "Copy Link": "link", "Split Left": "rectangle.lefthalf.inset.filled",
            "Split Right": "rectangle.righthalf.inset.filled", "Separate Split View": "rectangle",
            "Close Tab": "xmark", "Close Other Tabs": "xmark.square", "Close Tabs to the Right": "arrow.right.to.line",
        ], keys: ["New Tab": ["⌘", "T"], "Reload": ["⌘", "R"], "Close Tab": ["⌘", "W"], "Copy Link": ["⇧", "⌘", "C"]])
        GlassMenu(title: tab.displayTitle, entries: entries).show(in: window, at: event.locationInWindow, from: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { nil }

    @objc private func closeClicked() {
        strip?.close(self)
    }
}


/// A tab's close button: a soft circle under the pointer, a little stronger
/// while pressed, as Safari's are.
/// The tab's close button: an X drawn as two strokes at the exact centre
/// of its circle (a symbol image sits off centre by its alignment insets),
/// on a circular fill when pointed at or pressed.
final class TabCloseButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private let cross = CAShapeLayer()
    private static let arm: CGFloat = 3.6

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        image = nil
        wantsLayer = true
        setButtonType(.momentaryChange)
        cross.lineWidth = 1.6
        cross.lineCap = .round
        cross.fillColor = nil
        layer?.addSublayer(cross)
    }

    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mid = CGPoint(x: bounds.midX, y: bounds.midY), a = Self.arm
        let path = CGMutablePath()
        path.move(to: CGPoint(x: mid.x - a, y: mid.y - a)); path.addLine(to: CGPoint(x: mid.x + a, y: mid.y + a))
        path.move(to: CGPoint(x: mid.x - a, y: mid.y + a)); path.addLine(to: CGPoint(x: mid.x + a, y: mid.y - a))
        cross.frame = bounds
        cross.path = path
        cross.contentsScale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let alpha: CGFloat = isHighlighted ? 0.2 : hovering ? 0.12 : 0
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
            cross.strokeColor = (hovering || isHighlighted ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor
        }
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }
}

/// The capsule behind a split's two tabs, open where the tab in front is.
private final class PairBackdrop: NSView {
    private let fill = CAShapeLayer()
    private var size: NSSize = .zero
    private var hole: NSRect?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        fill.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The tab in front's place, in the backdrop's own coordinates; nil when neither is.
    func shape(size: NSSize, hole: NSRect?) {
        guard size != self.size || hole != self.hole else { return }
        self.size = size
        self.hole = hole
        fill.frame = NSRect(origin: .zero, size: size)
        fill.path = Self.path(size: size, hole: hole)
    }

    private static func path(size: NSSize, hole: NSRect?) -> CGPath {
        let r = size.height / 2
        let outer = CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: min(r, size.width / 2), cornerHeight: r, transform: nil)
        guard let hole, hole.width > 0 else { return outer }
        let hr = hole.height / 2
        let cut = CGPath(roundedRect: hole, cornerWidth: min(hr, hole.width / 2), cornerHeight: hr, transform: nil)
        // The tab is taller than the capsule: only what's inside it comes out.
        return outer.subtracting(cut)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        recolor()
    }
    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.fillColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
    }
}
