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

        var fresh: [TabItemView] = []
        items = browser.tabs.map { tab in
            if let item = items.first(where: { $0.tab === tab }) { return item }
            let item = TabItemView(tab: tab, strip: self)
            addSubview(item)
            fresh.append(item)
            return item
        }
        for item in items {
            item.isFront = item.tab === browser.selected
            item.refresh()
        }

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
            item.layoutWidth = item.frame.width
            item.isLeaving = true
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
    }

    func refresh(_ tab: Tab) {
        items.first { $0.tab === tab }?.refresh()
    }

    /// Selection is a state: it changes at once, as in any Mac list.
    func select(_ tab: Tab?) {
        for item in items { item.isFront = item.tab === tab }
    }

    func prefsChanged() {
        items.forEach { $0.needsLayout = true }
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
                item.layer?.zPosition = 10
            }
            // The tab stays under the pointer, along the row, no further than its ends.
            let x = max(0, min(bounds.width - item.frame.width, point.x - grab))
            Motion.still { item.setFrameOrigin(NSPoint(x: x, y: 0)) }
            let target = slot(at: x + item.frame.width / 2)
            if let index = items.firstIndex(of: item), index != target {
                items.remove(at: index)
                items.insert(item, at: target)
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
            Motion.animate(0.18, { item.animator().frame = target }, completion: { item.layer?.zPosition = 0 })
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
    var isFront = false { didSet { if isFront != oldValue { restyle() } } }
    private var isHovered = false { didSet { if isHovered != oldValue { restyle() } } }

    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let fade = CAGradientLayer()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(tab: Tab, strip: TabStripView) {
        self.tab = tab
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byClipping
        label.cell?.truncatesLastVisibleLine = false
        label.wantsLayer = true
        label.maximumNumberOfLines = 1
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        addSubview(label)

        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close Tab"
        closeButton.setAccessibilityLabel("Close Tab")
        addSubview(closeButton)

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

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsLayout = true }

    // MARK: content

    func refresh() {
        label.stringValue = tab.displayTitle
        toolTip = tab.url.map { "\(tab.displayTitle)\n\(Address.display($0))" } ?? tab.displayTitle
        setAccessibilityLabel(tab.displayTitle)
        if tab.isLoading && tab.favicon == nil {
            spinner.startAnimation(nil)
            icon.isHidden = true
        } else {
            spinner.stopAnimation(nil)
            icon.isHidden = false
        }
        icon.image = tab.favicon ?? NSImage(systemSymbolName: tab.isPrivate ? "hand.raised.fill" : "globe",
                                            accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = tab.favicon == nil ? .secondaryLabelColor : nil
        restyle()
        needsLayout = true
    }

    private func restyle() {
        label.textColor = isFront ? .labelColor : .secondaryLabelColor
        label.font = .systemFont(ofSize: 13, weight: isFront ? .semibold : .regular)
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
                // The selected segment of a macOS 27 segmented control: a
                // lighter capsule on the bar.
                color = dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 1, alpha: 0.95)
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
        closeButton.frame = NSRect(x: w - 30, y: (h - 20) / 2, width: 20, height: 20)
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

    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.browser?.menu(for: tab)
    }

    @objc private func closeClicked() {
        strip?.close(self)
    }
}
