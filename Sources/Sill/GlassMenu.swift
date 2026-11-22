import AppKit

/// A Raycast-style menu on Liquid Glass: a title, rows with a symbol, a name
/// and their keys, separators, a highlight that follows the pointer and the
/// arrow keys, and a field at the bottom that narrows the list as you type.
/// Return runs the highlighted row, Esc or a click elsewhere puts it away.
/// Used for the palette's Actions (⌘K) and a tab's right-click menu; pages
/// keep WebKit's own menus.
@MainActor
final class GlassMenu: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    struct Item {
        var title: String
        var symbol: String?
        var keys: [String] = []
        var isOn = false
        var isEnabled = true
        var run: () -> Void
    }

    enum Entry {
        case item(Item)
        case separator
    }

    /// The one on screen; showing another puts it away.
    private static var current: GlassMenu?

    private let title: String?
    private let entries: [Entry]
    private let panel: MenuPanel
    private let glass = NSGlassEffectView()
    private let body = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let search = NSTextField()
    private let searchRule = NSView()
    private var rows: [GlassMenuRow] = []
    private var rules: [NSView] = []
    private var visible: [Item] = []
    private var highlighted = 0
    private weak var parent: NSWindow?
    private weak var parentResponder: NSResponder?

    static let width: CGFloat = 320
    private static let rowHeight: CGFloat = 34
    private static let titleHeight: CGFloat = 30
    private static let ruleHeight: CGFloat = 11
    private static let searchHeight: CGFloat = 44
    private static let inset: CGFloat = 8

    init(title: String?, entries: [Entry]) {
        self.title = title
        self.entries = entries
        panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.onKey = { [weak self] event in self?.key(event) ?? false }

        glass.cornerRadius = 16
        glass.style = .regular
        glass.contentView = body
        panel.contentView = glass

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        body.addSubview(titleLabel)

        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 14)
        search.delegate = self
        body.addSubview(search)
        searchRule.wantsLayer = true
        body.addSubview(searchRule)
    }

    /// The menu's items from an AppKit menu built elsewhere, so a command
    /// is written once: each row sends its item's own action.
    static func entries(from menu: NSMenu, symbols: [String: String] = [:], keys: [String: [String]] = [:]) -> [Entry] {
        var result: [Entry] = []
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem {
                if case .item = result.last { result.append(.separator) }
                continue
            }
            let menuItem = item
            result.append(.item(Item(title: item.title, symbol: symbols[item.title], keys: keys[item.title] ?? [],
                                     isOn: item.state == .on, isEnabled: item.isEnabled) {
                if let action = menuItem.action { NSApp.sendAction(action, to: menuItem.target, from: menuItem) }
            }))
        }
        if case .separator = result.last { result.removeLast() }
        return result
    }

    // MARK: - showing

    /// Opens at `point` (window coordinates, bottom-left origin), growing
    /// down from it, or up from it when `above`, kept on the screen.
    func show(in window: NSWindow, at point: NSPoint, above: Bool = false, alignRight: Bool = false) {
        Self.current?.dismiss(animated: false)
        Self.current = self
        parent = window
        parentResponder = window.firstResponder

        let appearance = window.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        glass.tintColor = dark ? NSColor(white: 0.16, alpha: 0.3) : nil
        Ink.current = Ink(dark: dark)
        titleLabel.textColor = Ink.current.secondary
        search.textColor = Ink.current.primary
        search.placeholderAttributedString = NSAttributedString(string: "Search for actions…", attributes: [
            .foregroundColor: Ink.current.tertiary, .font: NSFont.systemFont(ofSize: 14),
        ])
        searchRule.layer?.backgroundColor = Ink.current.fill.cgColor

        rebuild(filter: "")
        let size = NSSize(width: Self.width, height: height)
        let origin = window.convertPoint(toScreen: point)
        var frame = NSRect(x: alignRight ? origin.x - size.width : origin.x,
                           y: above ? origin.y : origin.y - size.height,
                           width: size.width, height: size.height)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX + 6), screen.maxX - size.width - 6)
            if frame.minY < screen.minY + 6 { frame.origin.y = origin.y }
            frame.origin.y = min(max(frame.minY, screen.minY + 6), screen.maxY - size.height - 6)
        }
        panel.setFrame(frame, display: false)
        glass.frame = NSRect(origin: .zero, size: frame.size)
        body.frame = glass.bounds
        layout()
        window.addChildWindow(panel, ordered: .above)
        panel.alphaValue = Motion.reduced ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        if !Motion.reduced { Motion.animate(0.14) { panel.animator().alphaValue = 1 } }
    }

    func dismiss(animated: Bool = true) {
        guard Self.current === self else { return }
        Self.current = nil
        let panel = self.panel
        let finish = { [weak self] in
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self?.parent?.makeKey()
            if let responder = self?.parentResponder { self?.parent?.makeFirstResponder(responder) }
        }
        if animated && !Motion.reduced {
            Motion.animate(0.1, { panel.animator().alphaValue = 0 }, completion: finish)
        } else {
            finish()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click anywhere else, or another app: the menu goes.
        dismiss()
    }

    // MARK: - the list

    private var height: CGFloat {
        var h = Self.inset
        if title != nil, search.stringValue.isEmpty { h += Self.titleHeight }
        h += CGFloat(rows.count) * Self.rowHeight + CGFloat(rules.count) * Self.ruleHeight
        return h + Self.inset + Self.searchHeight
    }

    private func rebuild(filter: String) {
        rows.forEach { $0.removeFromSuperview() }
        rules.forEach { $0.removeFromSuperview() }
        rows = []
        rules = []
        visible = []
        let query = filter.lowercased().trimmingCharacters(in: .whitespaces)
        titleLabel.stringValue = title ?? ""
        titleLabel.isHidden = title == nil || !query.isEmpty
        for entry in entries {
            switch entry {
            case .separator:
                guard query.isEmpty, !rows.isEmpty else { continue }
                let rule = NSView()
                rule.wantsLayer = true
                rule.layer?.backgroundColor = Ink.current.fill.cgColor
                body.addSubview(rule)
                rules.append(rule)
                rows.append(GlassMenuRow.rulePlaceholder)
            case .item(let item):
                guard item.isEnabled, query.isEmpty || item.title.lowercased().contains(query) else { continue }
                let row = GlassMenuRow(item: item)
                let index = visible.count
                row.onHover = { [weak self] in self?.highlight(index) }
                row.onClick = { [weak self] in self?.run(index) }
                body.addSubview(row)
                rows.append(row)
                visible.append(item)
            }
        }
        rows.removeAll { $0 === GlassMenuRow.rulePlaceholder }
        highlighted = visible.isEmpty ? -1 : 0
        updateHighlight()
    }

    private func layout() {
        let w = panel.frame.width
        var y = Self.inset
        if !titleLabel.isHidden {
            titleLabel.frame = NSRect(x: 20, y: y + 8, width: w - 40, height: 16)
            y += Self.titleHeight
        }
        // Rows and rules in their original order.
        var rowIndex = 0
        var ruleIndex = 0
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        for entry in entries {
            switch entry {
            case .separator:
                guard query.isEmpty, ruleIndex < rules.count, rowIndex > 0 else { continue }
                rules[ruleIndex].frame = NSRect(x: 18, y: y + 5, width: w - 36, height: 1)
                ruleIndex += 1
                y += Self.ruleHeight
            case .item(let item):
                guard rowIndex < rows.count, rows[rowIndex].item.title == item.title else { continue }
                rows[rowIndex].frame = NSRect(x: Self.inset, y: y, width: w - Self.inset * 2, height: Self.rowHeight)
                rowIndex += 1
                y += Self.rowHeight
            }
        }
        y += Self.inset
        searchRule.frame = NSRect(x: 0, y: y, width: w, height: 1)
        search.frame = NSRect(x: 20, y: y + (Self.searchHeight - 20) / 2, width: w - 40, height: 20)
    }

    private func refit() {
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true)
        glass.frame = NSRect(origin: .zero, size: frame.size)
        body.frame = glass.bounds
        layout()
    }

    private func highlight(_ index: Int) {
        guard index != highlighted else { return }
        highlighted = index
        updateHighlight()
    }

    private func updateHighlight() {
        for (i, row) in rows.enumerated() { row.isHighlighted = i == highlighted }
    }

    private func run(_ index: Int) {
        guard visible.indices.contains(index) else { return }
        let item = visible[index]
        dismiss(animated: false)
        item.run()
    }

    // MARK: - keys

    func controlTextDidChange(_ obj: Notification) {
        rebuild(filter: search.stringValue)
        refit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !visible.isEmpty { highlight((highlighted + 1) % visible.count) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if !visible.isEmpty { highlight((highlighted - 1 + visible.count) % visible.count) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            run(highlighted)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
    }

    private func key(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { dismiss(); return true }
        return false
    }
}

/// The panel the menu lives in: it takes the keyboard (for its field) while
/// the browser stays the app's main window.
final class MenuPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// One row: symbol, title, keys or a check, and the highlight fill.
final class GlassMenuRow: NSView {
    static let rulePlaceholder = GlassMenuRow(item: GlassMenu.Item(title: "", run: {}))

    let item: GlassMenu.Item
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isHighlighted = false { didSet { needsDisplay = true } }

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var caps: [Keycap] = []
    private let check = NSImageView()

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(item: GlassMenu.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        if let symbol = item.symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            icon.contentTintColor = Ink.current.primary
            addSubview(icon)
        }
        label.stringValue = item.title
        label.font = .systemFont(ofSize: 14)
        label.textColor = Ink.current.primary
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        caps = item.keys.map { Keycap(text: $0) }
        caps.forEach(addSubview)
        if item.isOn {
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "On")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            check.contentTintColor = Ink.current.secondary
            addSubview(check)
        }
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func updateLayer() {
        layer?.backgroundColor = isHighlighted ? Ink.current.fill.cgColor : NSColor.clear.cgColor
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 12
        if item.symbol != nil {
            icon.frame = NSRect(x: x, y: (h - 18) / 2, width: 18, height: 18)
            x += 30
        }
        var right = bounds.width - 10
        for cap in caps.reversed() {
            cap.frame = NSRect(x: right - 22, y: (h - 20) / 2, width: 22, height: 20)
            right -= 25
        }
        if item.isOn {
            check.frame = NSRect(x: right - 16, y: (h - 14) / 2, width: 14, height: 14)
            right -= 22
        }
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: (h - labelHeight) / 2, width: max(0, right - 8 - x), height: labelHeight)
    }
}
