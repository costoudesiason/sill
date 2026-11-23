import AppKit

/// The bar across the top of the window, in place of an NSToolbar so its
/// margins are ours: back and forward in one glass capsule hard by the left
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

    let back = BarButton(symbol: "chevron.backward", label: "Back")
    let forward = BarButton(symbol: "chevron.forward", label: "Forward")
    let downloads = BarButton(symbol: "arrow.down.circle", label: "Downloads")
    let add = BarButton(symbol: "plus", label: "New Tab")
    let allTabs = BarButton(symbol: "square.on.square", label: "Show All Tabs")

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Room kept on the left for the window's traffic lights.
    var leadingInset: CGFloat = 0 { didSet { if leadingInset != oldValue { needsLayout = true } } }

    init(strip: TabStripView) {
        self.strip = strip
        super.init(frame: .zero)

        for glass in [navGlass, actionsGlass] {
            glass.effectIsInteractive = true
            glass.cornerRadius = Self.capsule / 2
        }
        navGlass.contentView = navContent
        actionsGlass.contentView = actionsContent
        navContent.addSubview(back)
        navContent.addSubview(divider)
        navContent.addSubview(forward)
        divider.wantsLayer = true
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
        addSubview(strip)
        strip.translatesAutoresizingMaskIntoConstraints = true

        back.toolTip = "Back"
        forward.toolTip = "Forward"
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

        navGlass.frame = NSRect(x: Self.margin + leadingInset, y: y, width: w * 2, height: c)
        navContent.frame = navGlass.bounds
        back.frame = NSRect(x: 0, y: 0, width: w, height: c)
        forward.frame = NSRect(x: w, y: 0, width: w, height: c)
        divider.frame = NSRect(x: w - 0.5, y: 9, width: 1, height: c - 18)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }

        let actionsWidth = w * 3
        actionsGlass.frame = NSRect(x: bounds.width - Self.margin - actionsWidth, y: y, width: actionsWidth, height: c)
        actionsContent.frame = actionsGlass.bounds
        downloads.frame = NSRect(x: 0, y: 0, width: w, height: c)
        add.frame = NSRect(x: w, y: 0, width: w, height: c)
        allTabs.frame = NSRect(x: w * 2, y: 0, width: w, height: c)

        let stripX = navGlass.frame.maxX + 8
        strip.frame = NSRect(x: stripX, y: y, width: max(0, actionsGlass.frame.minX - 8 - stripX), height: c)
    }

    /// Where the Downloads button is, in the bar's own coordinates: what a
    /// popover anchors to (a view inside glass reports its place unreliably
    /// while the glass lifts it).
    var downloadsRect: NSRect {
        NSRect(x: actionsGlass.frame.minX, y: actionsGlass.frame.minY, width: Self.buttonWidth, height: Self.capsule)
    }

    override func mouseDown(with event: NSEvent) {
        // A double-click on bare bar does what it does on any title bar.
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        super.mouseDown(with: event)
    }
}

/// A symbol button on the bar's glass: borderless, the glass gives the press.
final class BarButton: NSButton {
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .accessoryBarAction
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        setAccessibilityLabel(label)
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Set on every tab switch and back/forward change: redrawn only when it changes.
    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { contentTintColor = isEnabled ? .labelColor : .tertiaryLabelColor } }
    }
}
