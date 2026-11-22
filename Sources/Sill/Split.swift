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

/// "Choose a tab for this side": the open tabs in the system's pop-up menu.
/// Picking one fills the side; Cancel puts the page back on its own.
final class SplitChooser: NSView {
    var onPick: ((Tab) -> Void)?
    var onCancel: (() -> Void)?
    private let box = NSView()
    private let title = NSTextField(labelWithString: "Choose a tab for this side")
    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private var choices: [Tab] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.cornerCurve = .continuous
        addSubview(box)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        box.addSubview(title)
        popUp.target = self
        popUp.action = #selector(picked)
        box.addSubview(popUp)
        cancel.bezelStyle = .push
        cancel.target = self
        cancel.action = #selector(cancelled)
        box.addSubview(cancel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        }
    }

    func offer(_ tabs: [Tab]) {
        choices = tabs
        popUp.removeAllItems()
        let prompt = NSMenuItem(title: tabs.isEmpty ? "No other tabs open" : "Choose a Tab", action: nil, keyEquivalent: "")
        popUp.menu?.addItem(prompt)
        for tab in tabs {
            let item = NSMenuItem(title: tab.displayTitle, action: nil, keyEquivalent: "")
            if let icon = tab.favicon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            popUp.menu?.addItem(item)
        }
        popUp.selectItem(at: 0)
        popUp.isEnabled = !tabs.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width: CGFloat = min(320, bounds.width - 40)
        let height: CGFloat = 132
        box.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        title.frame = NSRect(x: 16, y: 20, width: width - 32, height: 18)
        popUp.frame = NSRect(x: 20, y: 50, width: width - 40, height: 28)
        cancel.sizeToFit()
        cancel.frame.origin = NSPoint(x: (width - cancel.frame.width) / 2, y: 90)
    }

    @objc private func picked() {
        let index = popUp.indexOfSelectedItem - 1
        guard index >= 0, index < choices.count else { return }
        onPick?(choices[index])
    }

    @objc private func cancelled() { onCancel?() }
}
