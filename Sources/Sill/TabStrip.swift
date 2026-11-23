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
    private var maxWidth: CGFloat { Preferences.shared.tabWidth == .fill ? .greatestFiniteMagnitude : 240 }

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
        super.mouseDown(with: event)
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
        Motion.animate(Self.reflow, {
            for item in leaving {
                item.animator().frame = NSRect(x: item.frame.minX, y: item.frame.minY, width: 0, height: item.frame.height)
                item.animator().alphaValue = 0
            }
            for item in items where item !== dragged {
                if let target = frames[ObjectIdentifier(item)] { item.animator().frame = target }
            }
        }, completion: {
            leaving.forEach { $0.removeFromSuperview() }
            fresh.forEach { $0.layoutWidth = nil }
        })
    }

    func refresh(_ tab: Tab) {
        items.first { $0.tab === tab }?.refresh()
    }

    /// Selection is a state: it changes at once, as in any Mac list.
    func select(_ tab: Tab?) {
        for item in items { item.isFront = item.tab === tab }
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
        guard let pair,
              let a = items.first(where: { $0.tab === pair.0 }), let b = items.first(where: { $0.tab === pair.1 }),
              let ia = items.firstIndex(of: a), let ib = items.firstIndex(of: b), abs(ia - ib) == 1 else {
            if !pairBackdrop.isHidden { pairBackdrop.isHidden = true }
            return
        }
        let frames = frames ?? targetFrames()
        guard let fa = frames[ObjectIdentifier(a)], let fb = frames[ObjectIdentifier(b)] else { return }
        let target = fa.union(fb).insetBy(dx: -2, dy: 0)
        let wasHidden = pairBackdrop.isHidden
        pairBackdrop.isHidden = false
        if animated && animates && !wasHidden {
            Motion.animate(Self.reflow) { pairBackdrop.animator().frame = target }
        } else {
            Motion.still { pairBackdrop.frame = target }
        }
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

    private func targetFrames() -> [ObjectIdentifier: NSRect] {
        let tabWidth = heldWidth ?? width(for: items.count)
        var result: [ObjectIdentifier: NSRect] = [:]
        var x: CGFloat = 0
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
        let index = Int((x / (tabWidth + spacing)).rounded(.down))
        return max(0, min(items.count - 1, index))
    }

    // MARK: - from the tabs

    func close(_ item: TabItemView) {
        // Hold the widths (unless it's the last tab) so the next close button
        // slides under the pointer, as long as the pointer stays in the strip.
        if item !== items.last { heldWidth = item.frame.width }
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
            // It trades places with a neighbour once its middle passes the
            // neighbour's middle, not at a slot's edge, so it never flickers
            // back and forth there.
            let center = x + item.frame.width / 2
            guard var index = items.firstIndex(of: item) else { continue }
            let start = index
            let frames = targetFrames()
            while index + 1 < items.count, let next = frames[ObjectIdentifier(items[index + 1])], center > next.midX {
                items.swapAt(index, index + 1); index += 1
            }
            while index > 0, let previous = frames[ObjectIdentifier(items[index - 1])], center < previous.midX {
                items.swapAt(index, index - 1); index -= 1
            }
            if index != start {
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
    /// this width and the frame clips them.
    var layoutWidth: CGFloat? { didSet { if layoutWidth != oldValue { Motion.still { layoutContents() } } } }
    var isPaired = false { didSet { if isPaired != oldValue { needsDisplay = true } } }
    var isFront = false { didSet { if isFront != oldValue { wearGlass(isFront); restyle() } } }

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
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(content)

        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        label.font = .systemFont(ofSize: 13)
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

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let frontFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

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
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let color: NSColor
            if isFront {
                color = .clear   // the glass is the selection
            } else if isPaired {
                color = dark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 1, alpha: 0.6)
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

    /// Laid out as the frame changes, inside whatever animation changes it,
    /// so the title, icon and close button travel with the tab instead of
    /// jumping to where they'll end up.
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
        let h = bounds.height
        let w = layoutWidth ?? bounds.width
        let narrow = w < 64
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
            return
        }
        icon.isHidden = tab.isLoading && tab.favicon == nil
        label.isHidden = false
        icon.frame = NSRect(x: 14, y: (h - iconSize) / 2, width: iconSize, height: iconSize)
        spinner.frame = icon.frame
        // Its centre as far from the right edge as the icon's is from the left.
        closeButton.frame = NSRect(x: w - 32, y: (h - 20) / 2, width: 20, height: 20)
        let labelX: CGFloat = 38
        let labelRight = showsClose ? w - 34 : w - 14
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: labelX, y: (h - labelHeight) / 2, width: max(0, labelRight - labelX), height: labelHeight)

        // Long titles fade out rather than end in an ellipsis.
        if label.intrinsicContentSize.width > label.frame.width, label.frame.width > 20 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fade.frame = label.bounds
            let start = max(0, (label.frame.width - 18) / label.frame.width)
            fade.locations = [0, NSNumber(value: start), 1]
            label.layer?.mask = fade
            CATransaction.commit()
        } else {
            label.layer?.mask = nil
        }
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

/// The capsule behind a split's two tabs.
private final class PairBackdrop: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            layer.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        }
        layer.borderWidth = 1
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
}
