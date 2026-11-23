import AppKit

/// ⌘T and ⌘L: one glass panel over the page with a field and a list, the
/// way Spotlight floats over the desktop. ⌘T opens what you pick in a new
/// tab; ⌘L (or a click on the tab in front) edits the address of this one.
/// Glass is the panel itself; the rows inside it are plain content, and the
/// chosen row is a fill.
@MainActor
final class Palette: NSObject {
    enum Mode { case newTab, address, tabs }

    enum Item {
        case go(URL)
        case search(String)
        case suggestion(String)
        case tab(Tab)
        case visit(Visit)
    }

    enum Row {
        case header(String)
        case item(Item)
        var item: Item? { if case .item(let item) = self { return item }; return nil }
        var isHeader: Bool { if case .header = self { return true }; return false }
    }

    private weak var browser: BrowserWindowController?
    let catcher = PaletteCatcher()
    private let card = PaletteCard()
    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private let searchIcon = NSImageView()
    let field = PaletteField()
    private let scroll = NSScrollView()
    private let table = PaletteTable()
    private let footer = FlippedView()
    /// The footer's controls are Liquid Glass of their own, as in Raycast and
    /// Spotlight: a round button on the left, and on the right a capsule that
    /// does what Return does or opens the chosen row's other actions. One
    /// container holds both so the system renders them together.
    private let footerGlass = NSGlassEffectContainerView()
    private let footerContent = FlippedView()
    private let pill = FooterPill()
    private let settingsButton = NSButton()

    private(set) var isOpen = false
    private(set) var mode: Mode = .newTab
    private var rows: [Row] = []
    /// The text the rows were made for: what they set in semibold.
    private var shownQuery = ""
    private var suggestions: [String] = []
    private var suggestionTask: URLSessionDataTask?
    private var suggestionTimer: Timer?
    /// What was actually typed, not counting the inline completion.
    private var typed = ""
    private var completing = true

    static let width: CGFloat = 680
    static let fieldHeight: CGFloat = 58
    static let footerHeight: CGFloat = 58
    static let rowHeight: CGFloat = 40
    static let headerHeight: CGFloat = 28

    init(browser: BrowserWindowController) {
        self.browser = browser
        super.init()
        build()
    }

    private func build() {
        catcher.onClick = { [weak self] in self?.close() }

        glass.cornerRadius = 26
        glass.style = .regular
        glass.effectIsInteractive = false
        glass.contentView = content
        card.addSubview(glass)
        card.wantsLayer = true

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        searchIcon.contentTintColor = .secondaryLabelColor
        content.addSubview(searchIcon)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 21, weight: .regular)
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("Search or enter website")
        content.addSubview(field)

        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.refusesFirstResponder = true
        table.focusRingType = .none
        table.rowSizeStyle = .custom
        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onHover = { [weak self] row in
            guard let self, row < self.rows.count, self.rows[row].item != nil, self.table.selectedRow != row else { return }
            self.table.selectRowIndexes([row], byExtendingSelection: false)
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        content.addSubview(scroll)

        settingsButton.bezelStyle = .glass
        settingsButton.borderShape = .circle
        settingsButton.controlSize = .large
        settingsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        settingsButton.imagePosition = .imageOnly
        settingsButton.toolTip = "Settings (⌘,)"
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        pill.onPrimary = { [weak self] in self?.performSelected() }
        pill.onActions = { [weak self] in self?.showActions() }
        field.onCommandK = { [weak self] in self?.showActions() }
        footerContent.addSubview(settingsButton)
        footerContent.addSubview(pill)
        footerGlass.contentView = footerContent
        footerGlass.spacing = 8
        footer.addSubview(footerGlass)
        content.addSubview(footer)
    }

    // MARK: - opening and closing

    func open(_ mode: Mode, in stage: NSView) {
        guard let browser else { return }
        self.mode = mode
        // Glass picks its look from what's behind it a frame late; pin the
        // window's own, and fixed colours with it, before anything is drawn,
        // so no text (placeholder included) flips from dark to light.
        let appearance = stage.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let named = NSAppearance(named: appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
        card.appearance = named
        content.appearance = named
        Ink.current = Ink(dark: named?.name == .darkAqua)
        // Liquid Glass with a light dark tint in dark mode, as Raycast's: dark
        // enough that a white page behind doesn't turn it pale, light enough
        // to stay glass.
        glass.style = .regular
        glass.tintColor = Ink.current.dark ? NSColor(white: 0.16, alpha: 0.3) : nil
        field.textColor = Ink.current.primary
        searchIcon.contentTintColor = Ink.current.secondary
        pill.needsLayout = true
        if catcher.superview !== stage {
            catcher.frame = stage.bounds
            catcher.autoresizingMask = [.width, .height]
            stage.addSubview(catcher)
            stage.addSubview(card)
        }
        let initial: String
        switch mode {
        case .newTab, .tabs: initial = ""
        case .address:
            let url = browser.selected?.url
            initial = Preferences.shared.engine.query(in: url) ?? (url.map { $0.absoluteString } ?? "")
        }
        field.placeholderAttributedString = NSAttributedString(
            string: mode == .tabs ? "Search tabs" : mode == .newTab ? "Search or enter website" : "Search or enter address",
            attributes: [.foregroundColor: Ink.current.tertiary, .font: field.font!])
        field.stringValue = initial
        typed = initial
        completing = false
        suggestions = []
        layout(in: stage)
        // From scratch: the rows on screen were drawn in the last opening's colours.
        rebuild(fresh: true)

        let wasOpen = isOpen
        isOpen = true
        catcher.isHidden = false
        card.isHidden = false
        stage.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.textColor = Ink.current.primary
            editor.insertionPointColor = .controlAccentColor
            editor.typingAttributes = [.foregroundColor: Ink.current.primary, .font: field.font!]
            editor.selectAll(nil)
        }
        if !wasOpen { appear() }
    }

    func close(animated: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        suggestionTask?.cancel()
        suggestionTimer?.invalidate()
        catcher.isHidden = true
        let finish = { [weak self] in
            guard let self, !self.isOpen else { return }
            self.card.isHidden = true
            self.card.alphaValue = 1
        }
        if animated && !Motion.reduced {
            card.layer?.add(scaleAnimation(from: 1, to: 0.97, duration: Motion.quick), forKey: "scale")
            Motion.animate(Motion.quick, { card.animator().alphaValue = 0 }, completion: finish)
        } else {
            finish()
        }
        browser?.paletteClosed()
    }

    private func appear() {
        card.alphaValue = 0
        guard !Motion.reduced else { card.alphaValue = 1; return }
        card.layer?.add(scaleAnimation(from: 0.96, to: 1, duration: 0.26), forKey: "scale")
        Motion.animate(0.18) { card.animator().alphaValue = 1 }
    }

    /// Grows from (or shrinks toward) the card's centre: AppKit pins a view's
    /// anchor to its corner, so the transform carries its own centring.
    private func scaleAnimation(from: CGFloat, to: CGFloat, duration: TimeInterval) -> CAAnimation {
        let bounds = card.bounds
        func transform(_ scale: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = transform(from)
        animation.toValue = transform(to)
        animation.duration = duration
        animation.timingFunction = Motion.curve
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = to == 1
        return animation
    }

    func layout(in stage: NSView) {
        let top = TopBar.height
        let available = stage.bounds.height - top
        let width = min(Self.width, stage.bounds.width - 48)
        let height = min(468, max(Self.fieldHeight + 140, available - 80))
        let y = top + max(24, min(available * 0.11, 96))
        // The stage is flipped: y grows down.
        card.frame = NSRect(x: round((stage.bounds.width - width) / 2), y: round(y), width: width, height: height)
        glass.frame = card.bounds
        content.frame = glass.bounds
        let w = card.bounds.width
        searchIcon.frame = NSRect(x: 22, y: (Self.fieldHeight - 22) / 2, width: 22, height: 22)
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 54, y: (Self.fieldHeight - fieldHeight) / 2 + 1, width: w - 54 - 22, height: fieldHeight)
        scroll.frame = NSRect(x: 0, y: Self.fieldHeight, width: w, height: height - Self.fieldHeight - Self.footerHeight)
        footer.frame = NSRect(x: 0, y: height - Self.footerHeight, width: w, height: Self.footerHeight)
        layoutFooter()
    }

    func stageResized(_ stage: NSView) {
        guard isOpen || !card.isHidden else { return }
        layout(in: stage)
    }

    private func layoutFooter() {
        footerGlass.frame = footer.bounds
        footerContent.frame = footerGlass.bounds
        let w = footer.bounds.width
        let size: CGFloat = 36
        let y = (Self.footerHeight - size) / 2 - 2
        settingsButton.frame = NSRect(x: 12, y: y, width: size, height: size)
        let pillWidth = pill.fittingWidth
        pill.frame = NSRect(x: w - 12 - pillWidth, y: y, width: pillWidth, height: size)
    }

    // MARK: - results

    private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    private func rebuild(keepSelection: Bool = false, fresh: Bool = false) {
        guard let browser else { return }
        let previous = keepSelection ? selectedItemKey : nil
        let text = query
        var rows: [Row] = []
        let others = browser.tabs.filter { $0 !== browser.selected && !$0.isBlank }

        if mode == .tabs {
            // Every open tab, this one too, in strip order.
            let lowered = text.lowercased()
            let matching = browser.tabs.filter {
                text.isEmpty || $0.displayTitle.lowercased().contains(lowered)
                    || Address.display($0.url).lowercased().contains(lowered)
            }
            rows.append(.header(matching.count == 1 ? "1 Tab" : "\(matching.count) Tabs"))
            rows += matching.map { .item(.tab($0)) }
        } else if text.isEmpty {
            if !others.isEmpty {
                rows.append(.header("Open Tabs"))
                rows += others.sorted { $0.lastShown > $1.lastShown }.prefix(4).map { .item(.tab($0)) }
            }
            let openURLs = Set(browser.tabs.compactMap { $0.url.flatMap(History.key) })
            let recent = History.shared.recent(limit: 40).filter { !openURLs.contains($0.url) }
            if !recent.isEmpty && !browser.isPrivate {
                rows.append(.header("Recently Visited"))
                var hosts = Set<String>()
                for visit in recent where hosts.insert(Domains.bare(visit.address?.host())).inserted {
                    rows.append(.item(.visit(visit)))
                    if hosts.count == 8 { break }
                }
            }
        } else {
            // The top hit: what Return does.
            var top: [Item] = []
            let lowered = text.lowercased()
            if let url = Address.url(from: text) {
                top = [.go(url), .search(text)]
            } else {
                top = [.search(text)]
            }
            rows += top.map { .item($0) }

            let tabMatches = others.filter {
                $0.displayTitle.lowercased().contains(lowered) || Address.display($0.url).lowercased().contains(lowered)
            }
            if !tabMatches.isEmpty {
                rows.append(.header("Open Tabs"))
                rows += tabMatches.prefix(3).map { .item(.tab($0)) }
            }
            if !browser.isPrivate {
                let topURL = top.compactMap { if case .go(let url) = $0 { return History.key(url) }; return nil }.first
                let open = Set(tabMatches.compactMap { $0.url.flatMap(History.key) })
                let visits = History.shared.search(text, limit: 8).filter { $0.url != topURL && !open.contains($0.url) }
                if !visits.isEmpty {
                    rows.append(.header("History"))
                    rows += visits.prefix(6).map { .item(.visit($0)) }
                }
            }
            let fresh = suggestions.filter { $0.lowercased() != lowered }.prefix(5)
            if !fresh.isEmpty {
                rows.append(.header("\(Preferences.shared.engine.name) Suggestions"))
                rows += fresh.map { .item(.suggestion($0)) }
            }
        }
        show(rows, for: text, fresh: fresh)
        // The top hit, if it's a site: loaded ahead so Return opens it at once.
        if mode == .newTab, let first = rows.first(where: { $0.item != nil })?.item {
            switch first {
            case .go(let url): browser.prerenderSoon(url)
            case .visit(let visit): browser.prerenderSoon(visit.address)
            default: browser.prerenderSoon(nil)
            }
        }
        let current: Int? = mode == .tabs && text.isEmpty
            ? rows.firstIndex { if case .item(.tab(let tab)) = $0 { return tab === browser.selected }; return false }
            : nil
        // Nothing typed, nothing chosen: Return on an empty palette must not
        // jump to whatever happens to be first (a tab, a recent site). The
        // arrows choose; typing gives the top hit. The tab list still starts
        // on the tab in front.
        let index = previous.flatMap { key in rows.firstIndex { $0.item.map(Self.key) == key } }
            ?? current ?? (text.isEmpty && mode != .tabs ? nil : rows.firstIndex { $0.item != nil })
        select(index)
    }

    /// Puts the new rows in the table. Typing mostly changes what rows say,
    /// not how many there are or which are headers, so the rows on screen
    /// are told their new contents and stay where they are; only from the
    /// first row whose kind differs are rows taken out and put in. Reloading
    /// the table instead builds every row's views again on every key.
    private func show(_ new: [Row], for text: String, fresh: Bool) {
        let old = rows
        rows = new
        shownQuery = text
        guard !fresh, table.numberOfRows == old.count else { table.reloadData(); return }
        var same = 0
        while same < min(old.count, new.count), old[same].isHeader == new[same].isHeader { same += 1 }
        for row in 0..<same {
            switch (new[row], table.view(atColumn: 0, row: row, makeIfNecessary: false)) {
            case (.header(let title), let view as PaletteHeaderCell): view.show(title)
            case (.item(let item), let view as PaletteItemCell): view.show(item, query: text)
            default: break
            }
        }
        guard same < old.count || same < new.count else { return }
        table.beginUpdates()
        if same < old.count { table.removeRows(at: IndexSet(integersIn: same..<old.count), withAnimation: []) }
        if same < new.count { table.insertRows(at: IndexSet(integersIn: same..<new.count), withAnimation: []) }
        table.endUpdates()
    }

    private static func key(_ item: Item) -> String {
        switch item {
        case .go(let url): "go:" + url.absoluteString
        case .search(let q): "search:" + q
        case .suggestion(let q): "suggest:" + q
        case .tab(let tab): "tab:" + tab.id.uuidString
        case .visit(let visit): "visit:" + visit.url
        }
    }

    private var selectedItemKey: String? {
        let row = table.selectedRow
        guard row >= 0, row < rows.count, let item = rows[row].item else { return nil }
        return Self.key(item)
    }

    private func select(_ index: Int?) {
        guard let index, index < rows.count else {
            table.deselectAll(nil)
            updateFooter()
            return
        }
        table.selectRowIndexes([index], byExtendingSelection: false)
        table.scrollRowToVisible(index)
        updateFooter()
    }

    private func move(_ delta: Int) {
        let selectable = rows.indices.filter { rows[$0].item != nil }
        guard !selectable.isEmpty else { return }
        let current = selectable.firstIndex(of: table.selectedRow) ?? (delta > 0 ? -1 : selectable.count)
        let next = max(0, min(selectable.count - 1, current + delta))
        select(selectable[next])
    }

    private func updateFooter() {
        let row = table.selectedRow
        var text = mode == .newTab ? "Open in New Tab" : "Open"
        if row >= 0, row < rows.count, let item = rows[row].item {
            switch item {
            case .tab: text = "Switch to Tab"
            case .search, .suggestion: text = mode == .newTab ? "Search in New Tab" : "Search"
            default: break
            }
        }
        guard pill.primaryTitle != text else { return }
        pill.primaryTitle = text
        layoutFooter()
    }

    // MARK: - suggestions

    private func askForSuggestions() {
        suggestionTimer?.invalidate()
        suggestionTask?.cancel()
        let text = query
        guard Preferences.shared.suggestions, !(browser?.isPrivate ?? true), !text.isEmpty, text.count < 80,
              Address.url(from: text) == nil || text.contains(" "),
              let url = Preferences.shared.engine.suggestions(text)
        else {
            if !suggestions.isEmpty { suggestions = []; rebuild(keepSelection: true) }
            return
        }
        // Only once typing pauses, briefly.
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data else { return }
                    let list = Self.parseSuggestions(data)
                    DispatchQueue.main.async {
                        guard let self, self.isOpen, self.query == text else { return }
                        self.suggestions = list
                        self.rebuild(keepSelection: true)
                    }
                }
                self.suggestionTask = task
                task.resume()
            }
        }
    }

    nonisolated private static func parseSuggestions(_ data: Data) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: data))
            ?? String(data: data, encoding: .isoLatin1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        if let array = object as? [Any], array.count > 1, let list = array[1] as? [String] { return list }
        if let array = object as? [[String: Any]] { return array.compactMap { $0["phrase"] as? String } }
        return []
    }

    // MARK: - acting

    @objc private func openSettings() {
        close()
        AppDelegate.shared.showSettings(nil)
    }

    /// ⌘K or the pill's Actions: what else can be done with the chosen row.
    func showActions() {
        // ⌘K or a click on Actions while its menu is up closes it.
        guard GlassMenu.shouldOpen(from: pill) else { return }
        let row = table.selectedRow
        guard row >= 0, row < rows.count, let item = rows[row].item, let browser else { return }
        let menu = NSMenu()
        var url: URL?
        switch item {
        case .go(let u): url = u
        case .visit(let v): url = v.address
        case .tab(let t): url = t.url
        case .search(let q), .suggestion(let q): url = Preferences.shared.engine.search(q)
        }
        if case .tab(let tab) = item {
            menu.addItem(ClosureMenuItem(title: "Switch to Tab") { [weak self] in self?.perform(item) })
            menu.addItem(ClosureMenuItem(title: "Close Tab") { [weak self] in
                browser.close(tab)
                self?.rebuild()
            })
        } else if let url {
            menu.addItem(ClosureMenuItem(title: "Open in New Tab") { [weak self] in
                self?.close()
                browser.navigate(to: url, newTab: true, typed: true)
            })
            menu.addItem(ClosureMenuItem(title: "Open in Background Tab") { [weak self] in
                browser.addTab(url: url, select: false)
                self?.rebuild(keepSelection: true)
            })
            if mode == .address, browser.selected != nil {
                menu.addItem(ClosureMenuItem(title: "Open Here") { [weak self] in
                    self?.close()
                    browser.navigate(to: url, newTab: false, typed: true)
                })
            }
        }
        if let url {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Copy Link") { Pasteboard.copy(url) })
        }
        if case .visit(let visit) = item {
            menu.addItem(ClosureMenuItem(title: "Remove from History") { [weak self] in
                History.shared.remove(visit.url)
                self?.rebuild()
            })
        }
        // Raycast's way: a glass menu rising from the Actions pill, right-aligned.
        guard let window = pill.window else { return }
        let anchor = pill.convert(pill.actionsAnchor, to: nil)
        let entries = GlassMenu.entries(from: menu, symbols: [
            "Switch to Tab": "arrow.right.square", "Close Tab": "xmark.square",
            "Open in New Tab": "plus.square.on.square", "Open in Background Tab": "square.stack",
            "Open Here": "arrow.turn.down.right", "Copy Link": "link", "Remove from History": "trash",
        ], keys: ["Open in New Tab": ["↩"], "Switch to Tab": ["↩"], "Copy Link": ["⇧", "⌘", "C"]])
        let title: String
        switch item {
        case .tab(let tab): title = tab.displayTitle
        case .visit(let visit): title = visit.title.isEmpty ? Address.display(visit.address) : visit.title
        case .go(let url): title = Address.display(url)
        case .search(let q), .suggestion(let q): title = q
        }
        GlassMenu(title: title, entries: entries)
            .show(in: window, at: NSPoint(x: anchor.maxX, y: anchor.maxY + 8), above: true, alignRight: true, from: pill)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, let item = rows[row].item else { return }
        perform(item)
    }

    private func performSelected() {
        let row = table.selectedRow
        if row >= 0, row < rows.count, let item = rows[row].item {
            perform(item)
        } else if !query.isEmpty, mode != .tabs {
            perform(Address.url(from: query).map(Item.go) ?? .search(query))
        }
    }

    private func perform(_ item: Item) {
        guard let browser else { return }
        let engine = Preferences.shared.engine
        let mode = self.mode
        close()
        switch item {
        case .tab(let tab):
            browser.select(tab)
        case .go(let url):
            browser.navigate(to: url, newTab: mode == .newTab, typed: true)
        case .visit(let visit):
            if let url = visit.address { browser.navigate(to: url, newTab: mode == .newTab, typed: true) }
        case .search(let q), .suggestion(let q):
            browser.navigate(to: engine.search(q), newTab: mode == .newTab, typed: false)
        }
    }

    // MARK: - inline completion

    private func complete() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let text = editor.string
        typed = text
        guard completing, !text.isEmpty, editor.selectedRange().location == (text as NSString).length,
              let completion = History.shared.completion(for: text)
        else { return }
        browser?.expect(Address.url(from: completion))
        // Keep the case they typed; add the rest, selected, so typing on replaces it.
        let rest = String(completion.dropFirst(text.count))
        guard !rest.isEmpty else { return }
        let start = (text as NSString).length
        editor.string = text + rest
        editor.setSelectedRange(NSRange(location: start, length: (rest as NSString).length))
    }
}

// MARK: - Field and table delegates

extension Palette: NSTextFieldDelegate {
    func controlTextDidChange(_ note: Notification) {
        complete()
        completing = true
        rebuild()
        askForSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): performSelected(); return true
        case #selector(NSResponder.insertLineBreak(_:)): performSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            // First Esc takes back the completion; the next one closes.
            if textView.selectedRange().length > 0, textView.selectedRange().location > 0,
               NSMaxRange(textView.selectedRange()) == (textView.string as NSString).length, textView.string != typed {
                textView.string = String(textView.string.prefix(typed.count))
                rebuild()
                return true
            }
            close()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab accepts the completion.
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            typed = textView.string
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteToBeginningOfLine(_:)):
            completing = false
            // Deleting a selected completion shouldn't bring it straight back.
            if selector == #selector(NSResponder.deleteBackward(_:)), textView.selectedRange().length > 0,
               NSMaxRange(textView.selectedRange()) == (textView.string as NSString).length, textView.string != typed {
                textView.string = String(textView.string.prefix(textView.selectedRange().location))
                typed = textView.string
                rebuild()
                askForSuggestions()
                return true
            }
            return false
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.moveToBeginningOfDocument(_:)):
            return false
        default:
            return false
        }
    }
}

extension Palette: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < rows.count && rows[row].isHeader ? Self.headerHeight : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { row < rows.count && rows[row].item != nil }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let view = tableView.makeView(withIdentifier: PaletteHeaderCell.id, owner: nil) as? PaletteHeaderCell ?? PaletteHeaderCell()
            view.show(title)
            return view
        case .item(let item):
            let view = tableView.makeView(withIdentifier: PaletteItemCell.id, owner: nil) as? PaletteItemCell ?? PaletteItemCell()
            view.show(item, query: shownQuery)
            return view
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }
}

// MARK: - Ink

/// The palette's text colours, fixed for the window's light or dark look the
/// moment it opens. Dynamic colours inside glass resolve a frame late (and
/// the shared field editor starts from its last typing colour), which showed
/// as text turning from black to white; fixed colours have nothing to flip.
struct Ink {
    var dark: Bool
    var primary: NSColor { dark ? NSColor(white: 1, alpha: 0.94) : NSColor(white: 0, alpha: 0.86) }
    var secondary: NSColor { dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.5) }
    var tertiary: NSColor { dark ? NSColor(white: 1, alpha: 0.32) : NSColor(white: 0, alpha: 0.3) }
    var fill: NSColor { dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.06) }
    static var current = Ink(dark: false)
}

// MARK: - Views

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The card's own view: flipped so the palette lays out top-down.
final class PaletteCard: NSView {
    override var isFlipped: Bool { true }
}

/// Everything around the card: a click there puts the palette away.
final class PaletteCatcher: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func scrollWheel(with event: NSEvent) {}
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }
}

final class PaletteField: NSTextField {
    var onCommandK: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "k",
           currentEditor() != nil {
            onCommandK?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Two spaces stay two spaces: the system's "add full stop with double
    /// space" would turn the end of an address into "site.com." and fail it.
    @objc(textView:shouldChangeTextInRange:replacementString:)
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if replacementString == ". ", range.length == 1, (textView.string as NSString).substring(with: range) == " ",
           NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.characters == " " {
            textView.insertText(" ", replacementRange: NSRange(location: range.upperBound, length: 0))
            return false
        }
        // NSTextField answers this itself, but not where Swift can call it.
        let selector = NSSelectorFromString("textView:shouldChangeTextInRange:replacementString:")
        guard let inherited = class_getMethodImplementation(NSTextField.self, selector) else { return true }
        typealias Answer = @convention(c) (AnyObject, Selector, NSTextView, NSRange, NSString?) -> Bool
        return unsafeBitCast(inherited, to: Answer.self)(self, selector, textView, range, replacementString as NSString?)
    }
}

final class PaletteTable: NSTableView {
    /// The row under a moving pointer; only real movement counts, so a list
    /// changing under a still pointer doesn't steal the keyboard's choice.
    var onHover: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover?(row) }
    }
    override func drawBackground(inClipRect clipRect: NSRect) {}
}

/// The chosen row: a soft fill, rounded, inset from the glass's edge.
final class PaletteRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 8, dy: 1)
        Ink.current.fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
    }
}

final class PaletteHeaderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("header")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ title: String) {
        guard label.stringValue != title else { return }
        label.stringValue = title
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let ink = Ink.current.secondary
        if label.textColor != ink { label.textColor = ink }
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 20, y: 4)
    }
}

final class PaletteItemCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("item")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// What the row last said, so a row told the same again does no work.
    private var shown: (name: String, query: String, dark: Bool)?
    private var detailWidth: CGFloat = 0
    /// The rows' symbols, each made once rather than for every row on every key.
    private static var symbols: [String: NSImage] = [:]

    private static func symbolImage(_ name: String) -> NSImage? {
        if let image = symbols[name] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        symbols[name] = image
        return image
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = .labelColor
        addSubview(title)
        detail.font = .systemFont(ofSize: 12.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.alignment = .right
        addSubview(detail)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: Palette.Item, query: String) {
        var image: NSImage?
        var symbol: String?
        var name = ""
        var right = ""
        switch item {
        case .go(let url):
            image = Favicons.shared.cached(for: url)
            symbol = "globe"
            name = Address.display(url)
            right = "Website"
        case .search(let q):
            symbol = "magnifyingglass"
            name = q
            right = "Search \(Preferences.shared.engine.name)"
        case .suggestion(let q):
            symbol = "magnifyingglass"
            name = q
        case .tab(let tab):
            image = tab.favicon
            symbol = "square.on.square"
            name = tab.displayTitle
            right = tab === (tab.host as? BrowserWindowController)?.selected ? "Current Tab" : "Switch to Tab"
        case .visit(let visit):
            image = Favicons.shared.cached(for: visit.address)
            symbol = "clock"
            name = visit.title.isEmpty ? Address.display(visit.address) : visit.title
            right = Domains.bare(visit.address?.host())
        }
        let ink = Ink.current
        let picture = image ?? Self.symbolImage(symbol ?? "globe")
        let tint = image == nil ? ink.secondary : nil
        if icon.image !== picture { icon.image = picture }
        if icon.contentTintColor != tint { icon.contentTintColor = tint }
        if shown?.name != name || shown?.query != query || shown?.dark != ink.dark {
            shown = (name, query, ink.dark)
            title.attributedStringValue = Self.highlight(name, query)
            needsLayout = true
        }
        if detail.stringValue != right || detailWidth == 0 {
            detail.stringValue = right
            detailWidth = min(220, ceil(detail.attributedStringValue.size().width) + 4)
            needsLayout = true
        }
        if detail.textColor != ink.secondary { detail.textColor = ink.secondary }
    }

    /// The words typed, in semibold where they appear.
    private static func highlight(_ text: String, _ query: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14),
                                                                          .foregroundColor: Ink.current.primary])
        let lower = text.lowercased() as NSString
        for word in query.lowercased().split(separator: " ") where word.count > 0 {
            let range = lower.range(of: String(word))
            if range.location != NSNotFound {
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .semibold), range: range)
            }
        }
        return result
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 22, y: (h - 18) / 2, width: 18, height: 18)
        detail.frame = NSRect(x: bounds.width - 24 - detailWidth, y: (h - 16) / 2, width: detailWidth, height: 16)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: 52, y: (h - titleHeight) / 2, width: detail.frame.minX - 12 - 52, height: titleHeight)
    }
}

/// A key's symbol in a small rounded cap, as menus show shortcuts.
final class Keycap: NSView {
    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    /// Outlined, as Raycast draws its keys on glass: a hairline, no fill.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Ink.current.fill.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = Ink.current.tertiary.cgColor
        }
        label.textColor = Ink.current.secondary
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame = NSRect(x: 0, y: (bounds.height - label.frame.height) / 2, width: bounds.width, height: label.frame.height)
    }
}


/// A soft fill for controls that sit on the palette's glass: the label
/// colour, faint, resolved for light or dark as it's drawn.
enum Fill {
    static var soft: CGColor { NSColor.labelColor.withAlphaComponent(0.08).cgColor }
}

/// The footer's capsule, Liquid Glass: the main action with its ↩, and
/// Actions ⌘K. Interactive glass, so it answers a press as system controls do.
final class FooterPill: NSView {
    var onPrimary: (() -> Void)?
    var onActions: (() -> Void)?
    var primaryTitle = "" { didSet { primary.title = primaryTitle; needsLayout = true } }

    private let glass = NSGlassEffectView()
    private let row = FlippedView()
    private let primary = PillSegment(title: "Open", keys: ["↩"])
    private let actions = PillSegment(title: "Actions", keys: ["⌘", "K"])

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        glass.effectIsInteractive = true
        glass.contentView = row
        addSubview(glass)
        row.addSubview(primary)
        row.addSubview(actions)
        primary.onClick = { [weak self] in self?.onPrimary?() }
        actions.onClick = { [weak self] in self?.onActions?() }
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat { 6 + primary.fittingWidth + 2 + actions.fittingWidth + 6 }
    var actionsAnchor: NSRect { convert(actions.frame, from: row) }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        row.frame = glass.bounds
        let h = bounds.height - 8
        primary.frame = NSRect(x: 4, y: 4, width: primary.fittingWidth, height: h)
        actions.frame = NSRect(x: primary.frame.maxX + 2, y: 4, width: actions.fittingWidth, height: h)
    }
}

/// One half of the pill: words and their keys, a soft fill under the pointer.
final class PillSegment: NSView {
    var onClick: (() -> Void)?
    var title: String { didSet { label.stringValue = title; needsLayout = true } }
    private let label = NSTextField(labelWithString: "")
    private var caps: [Keycap] = []
    private var hovering = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(title: String, keys: [String]) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        addSubview(label)
        caps = keys.map { Keycap(text: $0) }
        caps.forEach(addSubview)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat {
        ceil(label.attributedStringValue.size().width) + 4 + 12 + 12 + CGFloat(caps.count) * 22 + CGFloat(max(0, caps.count - 1)) * 3 + 8
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func mouseDown(with event: NSEvent) {}

    override func updateLayer() {
        layer?.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = hovering ? Ink.current.fill.cgColor : NSColor.clear.cgColor
        }
    }

    override func layout() {
        super.layout()
        label.textColor = Ink.current.primary
        let h = bounds.height
        let size = label.intrinsicContentSize
        let width = ceil(label.attributedStringValue.size().width) + 4
        label.frame = NSRect(x: 12, y: (h - size.height) / 2, width: width, height: size.height)
        var x = label.frame.maxX + 10
        for cap in caps {
            cap.frame = NSRect(x: x, y: (h - 20) / 2, width: 22, height: 20)
            x += 25
        }
    }
}
