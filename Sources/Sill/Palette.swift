import AppKit
import SwiftUI
import Combine

/// ⌘T and ⌘L: one glass panel over the page with a field and a list, the
/// way Spotlight floats over the desktop. ⌘T opens what you pick in a new
/// tab; ⌘L (or a click on the tab in front) edits the address of this one.
/// Glass is the panel itself; the rows inside it are plain content, and the
/// chosen row is a fill.
@MainActor
final class Palette: NSObject {
    enum Mode { case newTab, address, tabs, history }

    enum Item {
        case go(URL)
        case search(String)
        case suggestion(String)
        /// A search made before, from history.
        case pastSearch(String)
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
    /// Over the end of the list: only its controls take clicks; between
    /// them, clicks go through to the rows underneath.
    private let footer = PassThroughView()
    /// The footer's controls are Liquid Glass of their own, as in Raycast and
    /// Spotlight: a round button on the left, and on the right a capsule that
    /// does what Return does or opens the chosen row's other actions. One
    /// container holds both so the system renders them together.
    private let footerGlass = NSGlassEffectContainerView()
    private let footerContent = FlippedView()
    private let pill = FooterPill()
    private let settingsButton = GlassIconButton(symbol: "slider.horizontal.3", label: "Settings (⌘,)")
    /// Settings in the card, in place of the field, list and footer, and the
    /// glass X that turns it back: the same size as the settings button.
    private var settingsHost: NSHostingView<PaletteSettingsView>?
    /// Back from a page of the settings (Agents) to their list: glass, in
    /// the card's other top corner, the X's twin.
    private let pageBackButton = GlassIconButton(symbol: "chevron.backward", label: "Back to Settings", weight: .semibold, pointSize: 16)
    private let settingsNav = SettingsNav()
    private var navWatch: AnyCancellable?
    private let backButton = GlassIconButton(symbol: "xmark", label: "Close Settings (Esc)", weight: .semibold, pointSize: 16)
    private(set) var showingSettings = false

    private(set) var isOpen = false
    private(set) var mode: Mode = .newTab
    private var rows: [Row] = []
    /// The text the rows were made for: what they set in semibold.
    private var shownQuery = ""
    private var suggestions: [String] = []
    /// The text `suggestions` were asked for: until the answer for newer
    /// text comes, only those that still begin with it are shown, so the
    /// list doesn't empty and fill again on every key.
    private var suggestionsFor = ""
    /// Answers already had while the palette is open: deleting back shows
    /// them at once.
    private var suggestionCache: [String: [String]] = [:]
    private var suggestionTask: URLSessionDataTask?
    private var suggestionTimer: Timer?
    /// What was actually typed, not counting the inline completion: what
    /// the rows, the search and the suggestions are made for.
    private var typed = ""
    /// The rest of a site's address, shown selected after what was typed.
    private var inline: String?
    private var completing = true
    /// What the field held when it opened: Esc goes back to it before it closes.
    private var opening = ""

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
        table.onRightClick = { [weak self] row, point in
            guard let self, row < self.rows.count, self.rows[row].item != nil else { return }
            self.table.selectRowIndexes([row], byExtendingSelection: false)
            self.updateFooter()
            self.showActions(at: point)
        }
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
        footer.passes = [footerGlass, footerContent]
        content.addSubview(footer)

        pageBackButton.target = self
        pageBackButton.action = #selector(settingsPageBack)
        pageBackButton.isHidden = true
        navWatch = settingsNav.$page.dropFirst().sink { [weak self] page in
            DispatchQueue.main.async { self?.showPageBack(page == .agents) }
        }
        backButton.target = self
        backButton.action = #selector(closeSettings)
        backButton.keyEquivalent = "\u{1b}"
        backButton.isHidden = true
    }

    @objc private func closeSettings() {
        // Esc closes what's on top first: the engine menu, then the Agents page.
        if GlassMenu.dismissCurrent() { return }
        if settingsNav.page == .agents { return settingsPageBack() }
        showSettings(false)
    }

    @objc private func settingsPageBack() {
        if Motion.reduced { settingsNav.page = .main } else { withAnimation(.smooth(duration: 0.28)) { settingsNav.page = .main } }
    }

    private func showPageBack(_ on: Bool) {
        if on {
            if pageBackButton.superview !== content { content.addSubview(pageBackButton) }
            layoutBackButton()
            pageBackButton.alphaValue = 0
            pageBackButton.isHidden = false
            Motion.animate(0.2) { pageBackButton.animator().alphaValue = 1 }
        } else {
            Motion.animate(0.16, { self.pageBackButton.animator().alphaValue = 0 }, completion: { [weak self] in
                if self?.settingsNav.page == .main { self?.pageBackButton.isHidden = true }
            })
        }
    }

    // MARK: - opening and closing

    /// The window's look, pinned on the card and its fixed colours. Again
    /// when the look changes with the palette open (Settings' Light/Dark):
    /// the card stayed in the old one until it was closed.
    func takeAppearance(of window: NSWindow?, rebuilding: Bool = true) {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let named = NSAppearance(named: appearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua)
        card.appearance = named
        content.appearance = named
        Ink.current = Ink(dark: named?.name == .darkAqua)
        // Liquid Glass with a light dark tint in dark mode, as Raycast's: dark
        // enough that a white page behind doesn't turn it pale, light enough
        // to stay glass.
        glass.style = .regular
        // (0.3 left it mid-grey over a white page, white text on it under
        // 3:1; at 0.55 it holds 4.5:1 or better, still glass over dark pages.)
        glass.tintColor = Ink.current.dark ? NSColor(white: 0.12, alpha: 0.55) : nil
        field.textColor = Ink.current.primary
        searchIcon.contentTintColor = Ink.current.secondary
        pill.needsLayout = true
        if rebuilding, card.superview != nil { rebuild(keepSelection: true, fresh: true) }
    }

    func open(_ mode: Mode, in stage: NSView) {
        guard let browser else { return }
        self.mode = mode
        // Glass picks its look from what's behind it a frame late; pin the
        // window's own, and fixed colours with it, before anything is drawn,
        // so no text (placeholder included) flips from dark to light.
        // Not drawn here: the rows are made once below, for this opening's text.
        takeAppearance(of: stage.window, rebuilding: false)
        ready(in: stage)
        // Above whatever came after it was readied, as when it was made here.
        if !raised, stage.subviews.last !== card {
            stage.addSubview(catcher)
            stage.addSubview(card)
        }
        raised = true
        // Always opens on the search, whatever it was left showing.
        if showingSettings { showSettings(false, animated: false) }
        let initial: String
        switch mode {
        case .newTab, .tabs, .history: initial = ""
        case .address:
            let url = browser.selected?.url
            initial = Preferences.shared.engine.query(in: url) ?? (url.map { $0.absoluteString } ?? "")
        }
        field.placeholderAttributedString = NSAttributedString(
            string: mode == .tabs ? "Search tabs" : mode == .history ? "Search history"
                : mode == .newTab ? (browser.isPrivate ? "Search privately or enter website" : "Search or enter website")
                : "Search or enter address",
            attributes: [.foregroundColor: Ink.current.tertiary, .font: field.font!])
        field.stringValue = initial
        typed = initial
        opening = initial
        inline = nil
        // The first letter completes too, as in Safari.
        completing = true
        suggestions = []
        suggestionsFor = ""
        suggestionCache = [:]
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
            Self.plain(editor)
            editor.selectAll(nil)
        }
        if !wasOpen { appear() }
    }

    /// Addresses and searches, typed as they are: none of the system's
    /// corrections, substitutions or predictions, which turned "--" into a
    /// dash, "teh" into "the", and drew grey guesses over the completion.
    private static func plain(_ editor: NSTextView) {
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.inlinePredictionType = .no
        editor.mathExpressionCompletionType = .no
        editor.writingToolsBehavior = .none
    }

    /// Brought above the window's other views once, on its first opening.
    private var raised = false

    /// In the window, put away, before it is first wanted (the window does
    /// this once it has settled): the first ⌘T then only shows it, rather
    /// than also building and laying out every view of it and its glass.
    func ready(in stage: NSView) {
        guard catcher.superview !== stage else { return }
        if !isOpen {
            catcher.isHidden = true
            card.isHidden = true
        }
        catcher.frame = stage.bounds
        catcher.autoresizingMask = [.width, .height]
        stage.addSubview(catcher)
        stage.addSubview(card)
        layout(in: stage)
    }

    /// `focusPage`: false when a page is about to be put in front and
    /// focused anyway (a new tab, another tab): focusing the one being left
    /// first woke its page for nothing.
    func close(animated: Bool = true, focusPage: Bool = true) {
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
        browser?.paletteClosed(focusPage: focusPage)
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
        // The list runs to the bottom of the card, under the footer's two
        // floating controls; its end is kept clear of them, so the last row
        // still scrolls into sight. (It stopped above the footer, which
        // showed as a slab of glass with the list cut off along its top.)
        scroll.frame = NSRect(x: 0, y: Self.fieldHeight, width: w, height: height - Self.fieldHeight)
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.footerHeight + 6, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: Self.footerHeight, right: 0)
        // Rows fade out under the controls, as a scroll edge does.
        scroll.wantsLayer = true
        let fade = (scroll.layer?.mask as? CAGradientLayer) ?? CAGradientLayer()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.15).cgColor]
        let h = max(1, scroll.bounds.height)
        fade.locations = [0, NSNumber(value: Double(max(0, (h - Self.footerHeight - 8) / h))), 1]
        // A layer's y grows up here: the clear end is at the bottom, start 1 → 0.
        fade.startPoint = CGPoint(x: 0.5, y: scroll.isFlipped ? 0 : 1)
        fade.endPoint = CGPoint(x: 0.5, y: scroll.isFlipped ? 1 : 0)
        scroll.layer?.mask = fade
        CATransaction.commit()
        footer.frame = NSRect(x: 0, y: height - Self.footerHeight, width: w, height: Self.footerHeight)
        layoutFooter()
        if showingSettings { settingsHost?.frame = content.bounds; layoutBackButton() }
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

    private var query: String { typed.trimmingCharacters(in: .whitespaces) }

    private func rebuild(keepSelection: Bool = false, fresh: Bool = false) {
        guard let browser else { return }
        let previous = keepSelection ? selectedItemKey : nil
        let text = query
        var rows: [Row] = []
        let others = browser.tabs.filter { $0 !== browser.selected && !$0.isBlank }

        if mode == .history {
            // ⌘Y: everything visited, newest first, under the day it was
            // last seen; typing narrows it to what matches.
            let visits = text.isEmpty
                ? History.shared.recent(limit: 400)
                : History.shared.search(text, limit: 300).sorted { $0.last > $1.last }
            var day: String?
            for visit in visits {
                let heading = Self.dayHeading(visit.last)
                if heading != day { rows.append(.header(heading)); day = heading }
                rows.append(.item(.visit(visit)))
            }
            if visits.isEmpty { rows.append(.header(text.isEmpty ? "No history yet" : "Nothing in history matches")) }
        } else if mode == .tabs {
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
            let recent = History.shared.recent(limit: History.recentLimit).filter { !openURLs.contains($0.url) }
            if !recent.isEmpty && !browser.isPrivate {
                rows.append(.header("Recently Visited"))
                var hosts = Set<String>()
                for visit in recent where hosts.insert(Domains.bare(visit.address?.host())).inserted {
                    rows.append(.item(.visit(visit)))
                    if hosts.count == 8 { break }
                }
            }
        } else {
            // The top hit, what Return does: the site the completion finished
            // (or the address typed), then a search for exactly what was
            // typed, never for the completion ("you", not "youtube.com").
            var top: [Item] = []
            let lowered = text.lowercased()
            if let inline, let url = Address.url(from: text + inline) {
                top.append(.go(url))
            } else if let url = Address.url(from: text) {
                top.append(.go(url))
            }
            top.append(.search(text))
            rows += top.map { .item($0) }

            // Searches: yours from before first, then the engine's, each once.
            var said: Set<String> = [lowered]
            var searches: [Item] = []
            if !browser.isPrivate {
                for q in History.shared.searches(matching: text, limit: 3) where said.insert(q.lowercased()).inserted {
                    searches.append(.pastSearch(q))
                }
            }
            for q in suggestions where searches.count < 6 {
                let lower = q.lowercased()
                guard suggestionsFor == text || lower.hasPrefix(lowered), said.insert(lower).inserted else { continue }
                searches.append(.suggestion(q))
            }
            if !searches.isEmpty {
                rows.append(.header("\(Preferences.shared.engine.name) Suggestions"))
                rows += searches.prefix(5).map { .item($0) }
            }

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
                // Results pages are the searches above, not pages of their own.
                // Bookmarks first: kept on purpose, they say more than a visit.
                let marks = Bookmarks.shared.search(text, limit: 3).filter { $0.url != topURL && !open.contains($0.url) }
                if !marks.isEmpty {
                    rows.append(.header("Bookmarks"))
                    rows += marks.map { .item(.visit($0.asVisit)) }
                }
                let marked = Set(marks.map(\.url))
                let visits = History.shared.search(text, limit: 14).filter {
                    $0.url != topURL && !open.contains($0.url) && !marked.contains($0.url)
                        && SearchEngine.google.query(in: $0.address) == nil
                }
                if !visits.isEmpty {
                    rows.append(.header("History"))
                    rows += visits.prefix(6).map { .item(.visit($0)) }
                }
            }
        }
        show(rows, for: text, fresh: fresh)
        // The top hit, if it's a site: loaded ahead so Return opens it at
        // once (in the address field, only connected to).
        if mode != .tabs, let first = rows.first(where: { $0.item != nil })?.item {
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
        case .suggestion(let q), .pastSearch(let q): "suggest:" + q.lowercased()
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

    /// Today, Yesterday, a weekday this week, else the date.
    private static func dayHeading(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 99
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return sameYear ? date.formatted(.dateTime.day().month(.wide)) : date.formatted(.dateTime.day().month(.wide).year())
    }

    private func updateFooter() {
        let row = table.selectedRow
        var text = mode == .newTab || mode == .history ? "Open in New Tab" : "Open"
        if row >= 0, row < rows.count, let item = rows[row].item {
            switch item {
            case .tab: text = "Switch to Tab"
            case .search, .suggestion, .pastSearch: text = mode == .newTab ? "Search in New Tab" : "Search"
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
            if !suggestions.isEmpty { suggestions = []; suggestionsFor = ""; rebuild(keepSelection: true) }
            return
        }
        // Had already (put in place before the rows were made): nothing to ask.
        if suggestionCache[text] != nil { return }
        // Only once typing pauses, briefly.
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                    guard let data else { return }
                    let list = Self.parseSuggestions(data)
                    DispatchQueue.main.async {
                        guard let self, self.isOpen else { return }
                        if self.suggestionCache.count > 300 { self.suggestionCache = [:] }
                        self.suggestionCache[text] = list
                        guard self.query == text else { return }
                        self.suggestions = list
                        self.suggestionsFor = text
                        self.rebuild(keepSelection: true)
                    }
                }
                self.suggestionTask = task
                task.resume()
            }
        }
    }

    /// The answer had before for this text, put in place before its rows are made.
    private func useCachedSuggestions() {
        if let cached = suggestionCache[query] { suggestions = cached; suggestionsFor = query }
    }

    nonisolated private static func parseSuggestions(_ data: Data) -> [String] {
        let object = (try? JSONSerialization.jsonObject(with: data))
            ?? String(data: data, encoding: .isoLatin1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        if let array = object as? [Any], array.count > 1, let list = array[1] as? [String] { return list }
        if let array = object as? [[String: Any]] { return array.compactMap { $0["phrase"] as? String } }
        return []
    }

    // MARK: - acting

    @objc private func openSettings() { showSettings(true) }

    /// The card turns to its settings (or back): what's there fades out as
    /// the other slides in from the side it lives on, at the same size.
    func showSettings(_ on: Bool, animated: Bool = true) {
        guard on != showingSettings else { return }
        showingSettings = on
        let searchParts: [NSView] = [searchIcon, field, scroll, footer]
        // A plain switch: only the settings' icons move.
        let shift: CGFloat = 0
        let duration: TimeInterval = 0
        if on {
            let host = makeSettings()
            let rest = content.bounds
            Motion.still {
                host.frame = rest.offsetBy(dx: shift, dy: 0)
                host.alphaValue = 0
                backButton.alphaValue = 0
            }
            if host.superview !== content { content.addSubview(host) }
            content.addSubview(backButton)
            layoutBackButton()
            host.isHidden = false
            backButton.isHidden = false
            // The back button as the page it opens on calls for (always the
            // list: reset when they last closed).
            pageBackButton.isHidden = settingsNav.page != .agents
            pageBackButton.alphaValue = 1
            // Keys go to the settings, never to the hidden field; Esc is the X's.
            if content.window?.makeFirstResponder(host) != true { content.window?.makeFirstResponder(nil) }
            Motion.animate(duration, {
                host.animator().frame = rest
                host.animator().alphaValue = 1
                backButton.animator().alphaValue = 1
                searchParts.forEach { $0.animator().alphaValue = 0 }
            }, completion: { [weak self] in
                guard let self, self.showingSettings else { return }
                searchParts.forEach { $0.isHidden = true }
            })
        } else {
            guard let host = settingsHost else { return }
            // At once, not when the fade ends: opened again straight away
            // (⌘, after closing), it came up on Agents with no back button.
            GlassMenu.dismissCurrent()
            settingsNav.page = .main
            pageBackButton.isHidden = true
            // A change of engine shows at once in what's listed.
            suggestionCache = [:]
            suggestions = []
            suggestionsFor = ""
            rebuild()
            askForSuggestions()
            searchParts.forEach { $0.isHidden = false }
            content.window?.makeFirstResponder(field)
            if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
            Motion.animate(duration, {
                host.animator().frame = content.bounds.offsetBy(dx: shift, dy: 0)
                host.animator().alphaValue = 0
                backButton.animator().alphaValue = 0
                pageBackButton.animator().alphaValue = 0
                searchParts.forEach { $0.animator().alphaValue = 1 }
            }, completion: { [weak self] in
                guard let self, !self.showingSettings else { return }
                // Hidden, not taken out: put back in, it was laid out and
                // drawn again from scratch (6 to 9 ms, measured; 2 ms shown again).
                host.isHidden = true
                self.backButton.isHidden = true

            })
        }
    }

    private func makeSettings() -> NSHostingView<PaletteSettingsView> {
        if let settingsHost { return settingsHost }
        let host = NSHostingView(rootView: PaletteSettingsView(onChoose: { [weak self] choice, rect in
            self?.choose(choice, at: rect)
        }, nav: settingsNav))
        settingsHost = host
        return host
    }

    /// The settings, made and laid out in the card, hidden, before they are
    /// first opened (the window does this once it is quiet, after readying
    /// the palette). Their first opening cost 86 ms made then, 2 ms made
    /// ahead (measured in a harness): SwiftUI's first layout of the list is
    /// most of it.
    func readySettings() {
        guard settingsHost == nil, card.superview != nil else { return }
        let host = makeSettings()
        host.isHidden = true
        host.frame = content.bounds
        content.addSubview(host)
        host.layoutSubtreeIfNeeded()
    }

    private func layoutBackButton() {
        let size: CGFloat = 40
        backButton.frame = NSRect(x: content.bounds.width - 12 - size, y: (Self.fieldHeight - size) / 2, width: size, height: size)
        pageBackButton.frame = NSRect(x: 12, y: (Self.fieldHeight - size) / 2, width: size, height: size)
    }

    /// A choice in the settings opens Sill's glass menu under its value.
    private func choose(_ choice: PaletteSettingsView.Choice, at rect: CGRect) {
        guard let host = settingsHost, let window = host.window,
              // A click on the value while its menu is up closes it, and only that.
              GlassMenu.shouldOpen(from: host) else { return }
        let prefs = Preferences.shared
        let entries: [GlassMenu.Entry]
        switch choice {
        case .engine:
            entries = SearchEngine.allCases.map { engine in
                .item(GlassMenu.Item(title: engine.name, isOn: prefs.engine == engine) { prefs.engine = engine })
            }
        case .clear(let data):
            entries = [
                .item(GlassMenu.Item(title: "History…", symbol: "clock") { [weak self] in
                    // ⌘Y with its clear menu: a range, not only everything.
                    DispatchQueue.main.async { self?.browser?.clearHistory(nil) }
                }),
                .item(GlassMenu.Item(title: "Cookies and Website Data…", symbol: "externaldrive", run: data)),
                .item(GlassMenu.Item(title: "Website Permissions…", symbol: "hand.raised") {
                    AppDelegate.shared.resetSitePermissions(nil)
                }),
            ]
        }
        // The rect is in the settings' own (top-left) space: under its right end.
        let corner = host.convert(NSPoint(x: rect.maxX - 14, y: rect.maxY - 4), to: nil)
        GlassMenu(title: nil, entries: entries, searchable: false).show(in: window, at: corner, alignRight: true, from: host)
    }

    /// Keeps a row's page as a bookmark, or lets it go, with Undo.
    private func toggleBookmark(_ url: URL, title: String) {
        if let index = Bookmarks.shared.index(of: url), let gone = Bookmarks.shared.remove(url) {
            browser?.toast("Removed Bookmark", action: ("Undo", { [weak self] in
                Bookmarks.shared.restore(gone, at: index)
                self?.rebuild(keepSelection: true)
            }))
        } else if Bookmarks.shared.add(url, title: title) {
            browser?.toast("Added Bookmark", action: ("Undo", { [weak self] in
                Bookmarks.shared.remove(url)
                self?.rebuild(keepSelection: true)
            }))
        }
        rebuild(keepSelection: true)
    }

    /// ⌘K or the pill's Actions: what else can be done with the chosen row.
    /// A right-click on a row shows the same at the pointer.
    func showActions(at point: NSPoint? = nil) {
        // ⌘K or a click on Actions while its menu is up closes it.
        guard point != nil || GlassMenu.shouldOpen(from: pill) else { return }
        let row = table.selectedRow
        guard row >= 0, row < rows.count, let item = rows[row].item, let browser else { return }
        let menu = NSMenu()
        var url: URL?
        switch item {
        case .go(let u): url = u
        case .visit(let v): url = v.address
        case .tab(let t): url = t.url
        case .search(let q), .suggestion(let q), .pastSearch(let q): url = Preferences.shared.engine.search(q)
        }
        if case .tab(let tab) = item {
            menu.addItem(ClosureMenuItem(title: "Switch to Tab") { [weak self] in self?.perform(item) })
            menu.addItem(ClosureMenuItem(title: "Close Tab") { [weak self] in
                browser.close(tab)
                self?.rebuild()
            })
        } else if let url {
            menu.addItem(ClosureMenuItem(title: "Open in New Tab") { [weak self] in
                self?.close(focusPage: false)
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
        var siteTitle: String?
        if case .visit(let visit) = item, let url = visit.address {
            let marked = Bookmarks.shared.contains(url)
            menu.addItem(ClosureMenuItem(title: marked ? "Remove Bookmark" : "Add Bookmark") { [weak self] in
                self?.toggleBookmark(url, title: visit.title)
            })
        }
        // A row from bookmarks that isn't in history has no history to remove.
        if case .visit(let visit) = item, History.shared.visits[visit.url] != nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Remove from History") { [weak self] in self?.removeSelectedVisit() })
            // The whole site, when there is more of it than this one page.
            if let host = visit.address?.host() {
                let site = Domains.bare(host)
                let more = History.shared.visits.values.contains { $0.url != visit.url && Domains.bare($0.address?.host()) == site }
                if more {
                    siteTitle = "Remove All from \(site)"
                    menu.addItem(ClosureMenuItem(title: siteTitle!) { [weak self] in self?.removeSite(site) })
                }
            }
        }
        if mode == .history {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Clear History…") { [weak self] in
                // After this menu has gone: one glass menu at a time.
                DispatchQueue.main.async { self?.showClearMenu() }
            })
        }
        // Raycast's way: a glass menu rising from the Actions pill, right-aligned.
        guard let window = pill.window else { return }
        let anchor = pill.convert(pill.actionsAnchor, to: nil)
        let entries = GlassMenu.entries(from: menu, symbols: [
            "Switch to Tab": "arrow.right.square", "Close Tab": "xmark.square",
            "Open in New Tab": "plus.square.on.square", "Open in Background Tab": "square.stack",
            "Open Here": "arrow.turn.down.right", "Copy Link": "link", "Remove from History": "trash",
            "Clear History…": "clock.arrow.circlepath", "Add Bookmark": "bookmark", "Remove Bookmark": "bookmark.slash",
        ].merging(siteTitle.map { [$0: "trash.square"] } ?? [:]) { a, _ in a },
        keys: ["Open in New Tab": ["↩"], "Switch to Tab": ["↩"], "Copy Link": ["⇧", "⌘", "C"],
               "Remove from History": ["⌘", "⌫"]])
        let title: String
        switch item {
        case .tab(let tab): title = tab.displayTitle
        case .visit(let visit): title = visit.title.isEmpty ? Address.display(visit.address) : visit.title
        case .go(let url): title = Address.display(url)
        case .search(let q), .suggestion(let q), .pastSearch(let q): title = q
        }
        if let point {
            GlassMenu(title: title, entries: entries, searchable: false).show(in: window, at: point, from: nil)
        } else {
            GlassMenu(title: title, entries: entries)
                .show(in: window, at: NSPoint(x: anchor.maxX, y: anchor.maxY + 8), above: true, alignRight: true, from: pill)
        }
    }

    // MARK: - removing history

    /// ⌘⌫ (or ⌫ with nothing typed) in ⌘Y, or Remove from History: the
    /// chosen page goes at once, the next one is chosen, and Undo brings it back.
    private func removeSelectedVisit() {
        let row = table.selectedRow
        guard mode == .history || mode == .newTab || mode == .address,
              row >= 0, row < rows.count, case .visit(let visit)? = rows[row].item,
              let gone = History.shared.remove(visit.url) else { return }
        rebuild()
        // The row that took its place, else the one before.
        let selectable = rows.indices.filter { rows[$0].item != nil }
        select(selectable.first { $0 >= row } ?? selectable.last)
        let name = visit.title.isEmpty ? Address.display(visit.address) : visit.title
        offerUndo("Removed “\(name)”", [gone])
    }

    private func removeSite(_ site: String) {
        let gone = History.shared.remove { Domains.bare($0.address?.host()) == site }
        rebuild()
        offerUndo(gone.count == 1 ? "Removed 1 page from \(site)" : "Removed \(gone.count) pages from \(site)", gone)
    }

    /// How far back to clear, as Safari asks it: the last hour, today, today
    /// and yesterday, or everything. Each but the last goes at once, with Undo.
    func showClearMenu() {
        // Never a click's toggle (it follows the Actions menu, or a menu
        // command), so not held back by a menu from the pill just closing.
        guard let window = pill.window else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let ranges: [(String, Date)] = [
            ("Last Hour", Date().addingTimeInterval(-3600)),
            ("Today", today),
            ("Today and Yesterday", calendar.date(byAdding: .day, value: -1, to: today) ?? today),
        ]
        // Only the ranges with something in them; nothing greyed out.
        var entries: [GlassMenu.Entry] = ranges.compactMap { title, since in
            let count = History.shared.visits.values.reduce(0) { $1.last >= since ? $0 + 1 : $0 }
            guard count > 0 else { return nil }
            return .item(GlassMenu.Item(title: "Clear \(title)", symbol: "clock",
                                        subtitle: count == 1 ? "1 page" : "\(count) pages") { [weak self] in
                let gone = History.shared.remove { $0.last >= since }
                self?.rebuild()
                self?.offerUndo("Cleared \(title.lowercased()) of history", gone)
            })
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.item(GlassMenu.Item(title: "Clear All History…", symbol: "trash") { [weak self] in
            AppDelegate.shared.clearHistory(nil)
            self?.rebuild()
        }))
        let anchor = pill.convert(pill.actionsAnchor, to: nil)
        GlassMenu(title: "Clear History", entries: entries, searchable: false)
            .show(in: window, at: NSPoint(x: anchor.maxX, y: anchor.maxY + 8), above: true, alignRight: true, from: pill)
    }

    private func offerUndo(_ text: String, _ gone: [Visit]) {
        guard !gone.isEmpty else { return }
        browser?.toast(text, action: ("Undo", { [weak self] in
            History.shared.restore(gone)
            self?.rebuild(keepSelection: true)
        }))
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
        // Whether another page comes to the front, and takes the keys itself.
        let handsOff: Bool
        switch item {
        case .tab(let tab): handsOff = tab !== browser.selected
        case .visit(let visit): handsOff = mode == .newTab && visit.address != nil
        case .go, .search, .suggestion, .pastSearch: handsOff = mode == .newTab
        }
        close(focusPage: !handsOff)
        switch item {
        case .tab(let tab):
            browser.select(tab)
        case .go(let url):
            browser.navigate(to: url, newTab: mode == .newTab, typed: true)
        case .visit(let visit):
            if let url = visit.address { browser.navigate(to: url, newTab: mode == .newTab || mode == .history, typed: true) }
        case .search(let q), .suggestion(let q), .pastSearch(let q):
            browser.navigate(to: engine.search(q), newTab: mode == .newTab, typed: false)
        }
    }

    // MARK: - inline completion

    /// After each change to the text: notes what was typed and, if it
    /// begins a site you've been to, puts the rest of its address after it,
    /// selected, so the next letter typed replaces it.
    private func complete() {
        inline = nil
        guard let editor = field.currentEditor() as? NSTextView else { typed = field.stringValue; return }
        let before = (typed as NSString).length
        let text = editor.string
        typed = text
        let length = (text as NSString).length
        // Not while a letter is being composed (accents, Japanese), nor on a
        // paste: what was pasted is what was meant. A paste from the Edit
        // menu or a right-click comes with no ⌘ key, but it brings more than
        // the one letter typing does.
        let event = NSApp.currentEvent
        let pasted = (event?.type == .keyDown && event?.modifierFlags.contains(.command) == true) || length - before > 1
        guard completing, !pasted, !editor.hasMarkedText(), !text.isEmpty,
              editor.selectedRange() == NSRange(location: length, length: 0),
              let completion = History.shared.completion(for: text),
              completion.lowercased().hasPrefix(text.lowercased())
        else { return }
        browser?.expect(Address.url(from: completion))
        // Keep the case they typed; add the rest, selected, so typing on replaces it.
        let rest = String(completion.dropFirst(text.count))
        guard !rest.isEmpty else { return }
        editor.string = text + rest
        editor.setSelectedRange(NSRange(location: length, length: (rest as NSString).length))
        // Undo knows nothing of the completion: undoing the typing under it
        // left half an address ("thub.com"). What's typed is short to retype.
        editor.undoManager?.removeAllActions()
        inline = rest
    }

    /// Whether the completion is there as it was put: after the text, selected.
    private func showsInline(_ editor: NSTextView) -> Bool {
        guard let inline else { return false }
        let text = editor.string as NSString, rest = (inline as NSString).length
        let range = editor.selectedRange()
        return range.length == rest && NSMaxRange(range) == text.length && editor.string == typed + inline
    }

    /// The completion, kept as typed text (Tab, →, End, a click past it).
    private func acceptInline(_ editor: NSTextView, moveToEnd: Bool) {
        inline = nil
        typed = editor.string
        if moveToEnd { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        useCachedSuggestions()
        rebuild()
        askForSuggestions()
    }

    /// The completion taken away, leaving what was typed (Esc, Delete).
    private func dropInline(_ editor: NSTextView) {
        inline = nil
        editor.string = typed
        editor.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
        rebuild()
    }
}

// MARK: - Field and table delegates

extension Palette: NSTextFieldDelegate {
    func controlTextDidChange(_ note: Notification) {
        complete()
        completing = true
        useCachedSuggestions()
        rebuild()
        askForSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            performSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            // First Esc takes back the completion; the next one closes.
            if showsInline(textView) { dropInline(textView); return true }
            // Then it puts back what the field opened with (nothing in ⌘T,
            // the page's address in ⌘L); only the next one closes.
            if textView.string != opening {
                textView.string = opening
                textView.selectAll(nil)
                typed = opening
                inline = nil
                rebuild()
                return true
            }
            close()
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Tab keeps the completion; with none, it stays in the field.
            if showsInline(textView) { acceptInline(textView, moveToEnd: true) }
            return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.moveToRightEndOfLine(_:)):
            guard showsInline(textView) else { return false }
            acceptInline(textView, moveToEnd: true)
            return true
        case #selector(NSResponder.moveLeft(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)),
             #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToLeftEndOfLine(_:)),
             #selector(NSResponder.moveWordLeft(_:)), #selector(NSResponder.moveWordRight(_:)):
            // The caret moves as usual, and the completion stays as text.
            if showsInline(textView) { acceptInline(textView, moveToEnd: false) }
            return false
        case #selector(NSResponder.deleteToBeginningOfLine(_:)) where mode == .history && table.selectedRow >= 0:
            // ⌘⌫, as in Safari's history and Finder: the chosen page goes.
            removeSelectedVisit()
            return true
        case #selector(NSResponder.deleteBackward(_:)) where mode == .history && textView.string.isEmpty && table.selectedRow >= 0:
            removeSelectedVisit()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            completing = false
            // Delete with the completion showing takes only the completion,
            // and the next letter completes again (no text change follows
            // to turn completing back on).
            if showsInline(textView) { dropInline(textView); completing = true; return true }
            return false
        case #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordBackward(_:)),
             #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteToEndOfLine(_:)),
             #selector(NSResponder.deleteWordForward(_:)):
            completing = false
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
    /// A right-click (or Control-click) on a row, with where, in window space.
    var onRightClick: ((Int, NSPoint) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override func rightMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onRightClick?(row, event.locationInWindow) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        super.mouseDown(with: event)
    }
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
        case .pastSearch(let q):
            symbol = "clock"
            name = q
            right = "Searched Before"
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

    /// Both halves sit `inset` in from every edge, so each highlight's
    /// curve runs parallel to the pill's (concentric), the end ones alike.
    private static let inset: CGFloat = 4
    var fittingWidth: CGFloat { Self.inset + primary.fittingWidth + 2 + actions.fittingWidth + Self.inset }
    var actionsAnchor: NSRect { convert(actions.frame, from: row) }

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        row.frame = glass.bounds
        let i = Self.inset
        let h = bounds.height - i * 2
        primary.frame = NSRect(x: i, y: i, width: primary.fittingWidth, height: h)
        // The last half runs to the same inset from the right end.
        actions.frame = NSRect(x: primary.frame.maxX + 2, y: i, width: bounds.width - i - (primary.frame.maxX + 2), height: h)
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

/// A view that takes no clicks itself: they go to its controls, or through
/// to whatever is under it.
final class PassThroughView: NSView {
    override var isFlipped: Bool { true }
    var passes: [NSView] = []
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || passes.contains(where: { $0 === hit }) ? nil : hit
    }
}
