import AppKit
import WebKit

/// Two tabs side by side in one window. A side may be waiting for its tab,
/// shown by a small chooser until one is picked.
@MainActor
final class SplitPair {
    var left: Tab?
    var right: Tab?
    /// The left page's share of the width, kept as the divider is dragged.
    var fraction: CGFloat = 0.5

    init(left: Tab?, right: Tab?) {
        self.left = left
        self.right = right
    }

    func contains(_ tab: Tab?) -> Bool { tab != nil && (left === tab || right === tab) }
    var isComplete: Bool { left != nil && right != nil }

    func other(than tab: Tab) -> Tab? { left === tab ? right : right === tab ? left : nil }

    func remove(_ tab: Tab) {
        if left === tab { left = nil }
        if right === tab { right = nil }
    }
}

/// The system's split view with its thin divider, holding the two pages.
final class PageSplitView: NSSplitView, NSSplitViewDelegate {
    let leftPane = PaneView()
    let rightPane = PaneView()
    var onResize: ((CGFloat) -> Void)?
    private var applying = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isVertical = true
        dividerStyle = .thin
        delegate = self
        addArrangedSubview(leftPane)
        addArrangedSubview(rightPane)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(fraction: CGFloat) {
        applying = true
        adjustSubviews()
        setPosition(round(bounds.width * fraction), ofDividerAt: 0)
        applying = false
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        max(proposed, 320)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        min(proposed, bounds.width - 320)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !applying, bounds.width > 0 else { return }
        onResize?(leftPane.frame.width / bounds.width)
    }
}

/// One side of the split: a page, or the chooser while it waits for one.
final class PaneView: NSView {
    override var isFlipped: Bool { true }

    func show(_ view: NSView) {
        guard view.superview !== self || subviews.count != 1 else { return }
        subviews.forEach { if $0 !== view { $0.removeFromSuperview() } }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        if view.superview !== self { addSubview(view) }
    }
}

/// The empty side of a split: your open tabs as a list, in the palette's
/// glass, each with its icon, title and site. A click fills the side; Cancel
/// puts the page back on its own.
final class SplitChooser: NSView {
    var onPick: ((Tab) -> Void)?
    var onCancel: (() -> Void)?
    private let glass = NSGlassEffectView()
    private let body = FlippedView()
    private let title = NSTextField(labelWithString: "Choose a tab for this side")
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "No other tabs are open.")
    private var tabs: [Tab] = []
    /// Only the rows in view, by place in the list: a hundred open tabs
    /// are a screenful of views, and the rest are made as they scroll in.
    private var rows: [Int: ChoiceRow] = [:]

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = 24
        glass.contentView = body
        addSubview(glass)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        body.addSubview(title)
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        body.addSubview(scroll)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        body.addSubview(empty)
        cancel.bezelStyle = .glass
        cancel.target = self
        cancel.action = #selector(cancelled)
        body.addSubview(cancel)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func offer(_ tabs: [Tab]) {
        rows.values.forEach { $0.removeFromSuperview() }
        rows = [:]
        self.tabs = tabs
        empty.isHidden = !tabs.isEmpty
        needsLayout = true
    }

    /// Off screen it lets go of the tabs it listed: one closed since would
    /// otherwise stay whole, page and web process, until the next split.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, !tabs.isEmpty { offer([]) }
    }

    private static let rowHeight: CGFloat = 40

    override func layout() {
        super.layout()
        let width = min(420, bounds.width - 48)
        let listHeight = min(CGFloat(max(tabs.count, 1)) * Self.rowHeight, bounds.height - 200)
        let height = 44 + max(listHeight, 40) + 64
        glass.frame = NSRect(x: (bounds.width - width) / 2, y: max(24, (bounds.height - height) / 2), width: width, height: height)
        body.frame = glass.bounds
        title.sizeToFit()
        title.frame.origin = NSPoint(x: 20, y: 18)
        scroll.frame = NSRect(x: 0, y: 44, width: width, height: max(listHeight, 40))
        list.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(tabs.count) * Self.rowHeight)
        fill()
        empty.frame = NSRect(x: 0, y: 56, width: width, height: 18)
        cancel.sizeToFit()
        cancel.frame.origin = NSPoint(x: (width - cancel.frame.width) / 2, y: height - cancel.frame.height - 16)
    }

    /// Makes and places the rows in view and a few either side; lets go of the rest.
    private func fill() {
        let visible = scroll.contentView.bounds
        let first = max(0, Int(visible.minY / Self.rowHeight) - 4)
        let last = min(tabs.count - 1, Int(visible.maxY / Self.rowHeight) + 4)
        for (i, row) in rows where i < first || i > last {
            row.removeFromSuperview()
            rows[i] = nil
        }
        guard first <= last else { return }
        for i in first...last {
            let row = rows[i] ?? {
                let tab = tabs[i]
                let row = ChoiceRow(tab: tab)
                row.onClick = { [weak self] in self?.onPick?(tab) }
                list.addSubview(row)
                rows[i] = row
                return row
            }()
            row.frame = NSRect(x: 8, y: CGFloat(i) * Self.rowHeight, width: list.frame.width - 16, height: Self.rowHeight)
        }
    }

    @objc private func scrolled() { fill() }

    @objc private func cancelled() { onCancel?() }
}

/// One open tab offered for the empty side.
private final class ChoiceRow: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let site = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(tab: Tab) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = tab.favicon == nil ? .secondaryLabelColor : nil
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        label.stringValue = tab.displayTitle
        label.font = .systemFont(ofSize: 14)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        site.stringValue = Domains.bare(tab.url?.host())
        site.font = .systemFont(ofSize: 12.5)
        site.textColor = .secondaryLabelColor
        site.alignment = .right
        addSubview(site)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.displayTitle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 18) / 2, width: 18, height: 18)
        let siteWidth = min(140, ceil(site.attributedStringValue.size().width) + 4)
        site.frame = NSRect(x: bounds.width - 12 - siteWidth, y: (h - 16) / 2, width: siteWidth, height: 16)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 42, y: (h - labelHeight) / 2, width: site.frame.minX - 10 - 42, height: labelHeight)
    }
}
