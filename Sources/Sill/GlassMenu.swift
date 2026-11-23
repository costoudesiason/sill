import AppKit

/// A Raycast-style menu on Liquid Glass: a title, rows with a symbol, a name
/// and their keys, separators, a highlight that follows the pointer and the
/// arrow keys, and a field at the bottom that narrows the list as you type.
/// Return runs the highlighted row, Esc or a click elsewhere puts it away.
/// Used for the palette's Actions (⌘K) and a tab's right-click menu; pages
/// keep WebKit's own menus.
///
/// It's drawn inside the browser window, over everything, as the palette is:
/// glass in a window of its own samples a rectangle behind that window and
/// shows odd shapes at its rounded corners. A clear layer under the card
/// catches a click anywhere else and puts the menu away, so that click does
/// nothing more (a second click on Actions closes, it doesn't reopen).
@MainActor
final class GlassMenu: NSObject, NSTextFieldDelegate {
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

    /// Pages' right-click menus use the glass menu (Web.swift).
    static var isEnabledForPages = true

    /// The one on screen; showing another puts it away.
    private static var current: GlassMenu?
    /// What opened the menu that just closed, and when: a click on the same
    /// control a moment later closed it (the click landed outside the menu)
    /// and must not open it again.
    private static var lastClosed: (source: ObjectIdentifier, at: Date)?
    private var source: ObjectIdentifier?

    static var isOpen: Bool { current != nil }

    /// Puts away whatever menu is open. True if there was one.
    @discardableResult
    static func dismissCurrent() -> Bool {
        guard let current else { return false }
        current.dismiss()
        return true
    }

    /// Whether a click on `source` should open the menu, or is the click that
    /// just closed it.
    static func shouldOpen(from source: AnyObject) -> Bool {
        if current?.source == ObjectIdentifier(source) { current?.dismiss(); return false }
        if let last = lastClosed, last.source == ObjectIdentifier(source), Date().timeIntervalSince(last.at) < 0.4 { return false }
        return true
    }

    private let title: String?
    private let entries: [Entry]
    private let overlay = MenuOverlay()
    private let glass = NSGlassEffectView()
    private let body = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let search = MenuSearchField()
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
    private static let inset: CGFloat = 9

    /// A short list of choices (a setting's values) has no search field.
    private let searchable: Bool

    init(title: String?, entries: [Entry], searchable: Bool = true) {
        self.title = title
        self.entries = entries
        self.searchable = searchable
        super.init()
        overlay.onOutsideClick = { [weak self] in self?.dismiss() }
        overlay.autoresizingMask = [.width, .height]
        search.onCommandK = { [weak self] in self?.dismiss() }

        glass.cornerRadius = 22
        glass.style = .regular
        glass.contentView = body
        overlay.addSubview(glass)

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
    /// down from it, or up from it when `above`, kept inside the window.
    func show(in window: NSWindow, at point: NSPoint, above: Bool = false, alignRight: Bool = false, from source: AnyObject? = nil) {
        guard let host = window.contentView else { return }
        // A tab's preview card doesn't stay up over its menu.
        (window.windowController as? BrowserWindowController)?.hidePreview(animated: false)
        Self.current?.dismiss(animated: false)
        Self.current = self
        self.source = source.map(ObjectIdentifier.init)
        parent = window
        parentResponder = window.firstResponder

        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        overlay.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        glass.tintColor = dark ? NSColor(white: 0.16, alpha: 0.3) : nil
        Ink.current = Ink(dark: dark)
        titleLabel.textColor = Ink.current.secondary
        search.textColor = Ink.current.primary
        search.placeholderAttributedString = NSAttributedString(string: "Search for actions…", attributes: [
            .foregroundColor: Ink.current.tertiary, .font: NSFont.systemFont(ofSize: 14),
        ])
        searchRule.layer?.backgroundColor = Ink.current.fill.cgColor

        overlay.frame = host.bounds
        host.addSubview(overlay)
        rebuild(filter: "")
        let size = NSSize(width: Self.width, height: height)
        let at = overlay.convert(point, from: nil)
        var frame = NSRect(x: alignRight ? at.x - size.width : at.x,
                           y: above ? at.y : at.y - size.height,
                           width: size.width, height: size.height)
        let room = overlay.bounds.insetBy(dx: 8, dy: 8)
        if frame.minY < room.minY { frame.origin.y = at.y }
        frame.origin.x = min(max(frame.minX, room.minX), room.maxX - size.width)
        frame.origin.y = min(max(frame.minY, room.minY), room.maxY - size.height)
        glass.frame = frame
        body.frame = glass.bounds
        layout()
        window.makeFirstResponder(search)
        guard !Motion.reduced else { return }
        glass.alphaValue = 0
        Motion.animate(0.14) { glass.animator().alphaValue = 1 }
    }

    /// Runs once the menu has gone, picked from or not.
    var onDismiss: (() -> Void)?

    func dismiss(animated: Bool = true) {
        guard Self.current === self else { return }
        Self.current = nil
        let gone = onDismiss
        onDismiss = nil
        gone?()
        if let source { Self.lastClosed = (source, Date()) }
        let overlay = self.overlay
        overlay.onOutsideClick = nil
        if let responder = parentResponder, parent?.firstResponder === search.currentEditor() || parent?.firstResponder === search {
            parent?.makeFirstResponder(responder)
        }
        if animated && !Motion.reduced {
            Motion.animate(0.1, { glass.animator().alphaValue = 0 }, completion: { overlay.removeFromSuperview() })
        } else {
            overlay.removeFromSuperview()
        }
    }

    // MARK: - the list

    private var height: CGFloat {
        var h = Self.inset
        if title != nil, search.stringValue.isEmpty { h += Self.titleHeight }
        h += CGFloat(rows.count) * Self.rowHeight + CGFloat(rules.count) * Self.ruleHeight
        return h + Self.inset + (searchable ? Self.searchHeight : 0)
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
        let w = glass.frame.width
        var y = Self.inset
        if !titleLabel.isHidden {
            // In line with the rows' icons below it.
            titleLabel.frame = NSRect(x: Self.inset + 12, y: y + 8, width: w - 40, height: 16)
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
                rules[ruleIndex].frame = NSRect(x: Self.inset + 10, y: y + 5, width: w - (Self.inset + 10) * 2, height: 1)
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
        searchRule.isHidden = !searchable
        // Without its field showing, the field still takes the arrow keys and Return.
        search.alphaValue = searchable ? 1 : 0
        searchRule.frame = NSRect(x: 0, y: y, width: w, height: 1)
        search.frame = searchable
            ? NSRect(x: Self.inset + 12, y: y + (Self.searchHeight - 20) / 2, width: w - 40, height: 20)
            : NSRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func refit() {
        var frame = glass.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - frame.height
        glass.frame = frame
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

/// The clear layer over the window while a menu is open: a click anywhere
/// but the card puts the menu away and goes no further.
final class MenuOverlay: NSView {
    var onOutsideClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onOutsideClick?() }
    override func rightMouseDown(with event: NSEvent) { onOutsideClick?() }
    override func otherMouseDown(with event: NSEvent) { onOutsideClick?() }
    override func scrollWheel(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The menu's search field: ⌘K again closes the menu, as in Raycast.
final class MenuSearchField: NSTextField {
    var onCommandK: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "k", currentEditor() != nil {
            onCommandK?()
            return true
        }
        return super.performKeyEquivalent(with: event)
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
        layer?.cornerRadius = 13
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
        var x: CGFloat = 10
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
