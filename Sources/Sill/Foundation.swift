import AppKit
import Combine
import QuartzCore

// MARK: - Motion

/// One curve and a few durations for the whole app. UI motion stays under
/// 300 ms, eases out hard, never bounces, and turns into a plain cut when
/// the Mac asks for less motion.
enum Motion {
    /// Strong ease-out: quick to respond, soft to land.
    static let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    static let quick: TimeInterval = 0.14
    static let standard: TimeInterval = 0.24

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func animate(_ duration: TimeInterval = standard,
                        _ changes: () -> Void,
                        completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduced ? 0 : duration
            context.timingFunction = curve
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }

    /// Changes that must not animate, even inside someone else's group.
    static func still(_ changes: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }
}

// MARK: - After the frame

@MainActor
enum Frame {
    /// Runs `work` on the main thread once what has changed so far has been
    /// committed for the screen. Work sent with DispatchQueue.main.async
    /// runs before that (the run loop serves the main queue ahead of Core
    /// Animation's commit, measured), so it held up the very frame it was
    /// meant to follow.
    static func afterCommit(_ work: @escaping @MainActor () -> Void) {
        // Last of the observers at the end of a run loop pass, after Core
        // Animation's own (order 2,000,000), and only once.
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, false, CFIndex.max) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

// MARK: - Preferences

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing, kagi, ecosia

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: "Google"
        case .duckduckgo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        }
    }

    func search(_ query: String) -> URL {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        let base: String
        switch self {
        case .google: base = "https://www.google.com/search?client=safari&q="
        case .duckduckgo: base = "https://duckduckgo.com/?q="
        case .bing: base = "https://www.bing.com/search?q="
        case .kagi: base = "https://kagi.com/search?q="
        case .ecosia: base = "https://www.ecosia.org/search?q="
        }
        return URL(string: base + q)!
    }

    /// Where suggestions come from: an OpenSearch-style `[query, [suggestion…]]`.
    func suggestions(_ query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        switch self {
        case .google: return URL(string: "https://suggestqueries.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=" + q)
        case .duckduckgo, .kagi: return URL(string: "https://duckduckgo.com/ac/?type=list&q=" + q)
        case .bing: return URL(string: "https://api.bing.com/osjson.aspx?query=" + q)
        case .ecosia: return URL(string: "https://ac.ecosia.org/autocomplete?type=list&q=" + q)
        }
    }

    /// The query, if `url` is one of this engine's result pages.
    func query(in url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let isEngine = ["google.", "duckduckgo.com", "bing.com", "kagi.com", "ecosia.org"].contains { host.contains($0) }
        guard isEngine, url.path.contains("search") || host.contains("duckduckgo") else { return nil }
        return items.first { $0.name == "q" }?.value
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()
}

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum TabWidth: String, CaseIterable, Identifiable {
    /// Tabs share the whole bar, as Safari's do.
    case fill
    /// Tabs keep a comfortable width, centred in the bar, narrowing as more open.
    case compact
    var id: String { rawValue }
    var name: String { self == .fill ? "Fill the bar" : "Compact" }
}

enum CloseButtons: String, CaseIterable, Identifiable {
    case hover, always
    var id: String { rawValue }
    var name: String { self == .hover ? "On hover" : "Always" }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()
    /// A test copy (SILL_PROFILE) keeps settings of its own: it never touches yours.
    let store: UserDefaults = Places.testProfile.flatMap { UserDefaults(suiteName: "com.iasoncostoudes.sill.chromium.\($0)") } ?? .standard

    // Looks
    @Published var theme: Theme { didSet { store.set(theme.rawValue, forKey: "theme") } }
    /// The bar shows the desktop through Liquid Glass; off, it's the window's own solid colour.
    @Published var glassBar: Bool { didSet { store.set(glassBar, forKey: "glassBar") } }
    /// How much the glass is washed toward the window colour: 0 clear, 1 solid.
    @Published var glassWash: Double { didSet { store.set(glassWash, forKey: "glassWash") } }
    @Published var cornerRadius: Double { didSet { store.set(cornerRadius, forKey: "cornerRadius") } }
    /// Corners rounder than the system's: costs a see-through window.
    @Published var roundCorners: Bool { didSet { store.set(roundCorners, forKey: "roundCorners") } }
    @Published var tabWidth: TabWidth { didSet { store.set(tabWidth.rawValue, forKey: "tabWidth") } }
    @Published var closeButtons: CloseButtons { didSet { store.set(closeButtons.rawValue, forKey: "closeButtons") } }
    @Published var showsLinkPreview: Bool { didSet { store.set(showsLinkPreview, forKey: "showsLinkPreview") } }
    /// A card with a picture of the page when the pointer rests on a tab.
    @Published var showsTabPreviews: Bool { didSet { store.set(showsTabPreviews, forKey: "tabPreviews") } }
    // Tabs and media
    @Published var autoPictureInPicture: Bool { didSet { store.set(autoPictureInPicture, forKey: "autoPiP") } }
    @Published var sleepsTabs: Bool { didSet { store.set(sleepsTabs, forKey: "sleepsTabs") } }
    /// claude.ai kept loaded out of sight so its links open at once (Warm.swift).
    @Published var keepsClaudeReady: Bool {
        didSet {
            store.set(keepsClaudeReady, forKey: "warmClaude")
            MainActor.assumeIsolated {
                if keepsClaudeReady { WarmSite.shared.warm(after: 0) } else { WarmSite.shared.drop() }
            }
        }
    }
    /// Agents on this Mac may drive Sill over its local socket (sill-mcp).
    @Published var agentControl: Bool { didSet { store.set(agentControl, forKey: "agentControl") } }
    /// claude.ai (or another app on the internet) may drive Sill through your relay (Connector.swift).
    @Published var remoteConnector: Bool { didSet { store.set(remoteConnector, forKey: "remoteConnector") } }
    /// The relay's address, e.g. https://sill-relay.up.railway.app.
    @Published var connectorRelay: String { didSet { store.set(connectorRelay, forKey: "connectorRelay") } }
    /// When agents ask first: "auto" (risky steps, judged on device), "always", "never" (AgentJudge).
    @Published var agentAsk: String { didSet { store.set(agentAsk, forKey: "agentAsk") } }
    /// claude.ai may run scripts in pages (page_eval): off unless you turn it on.
    @Published var remoteScripts: Bool { didSet { store.set(remoteScripts, forKey: "remoteScripts") } }
    /// claude.ai sign-ins made before this moment no longer work (Sign out claude.ai).
    @Published var connectorNotBefore: Double { didSet { store.set(connectorNotBefore, forKey: "connectorNotBefore") } }
    @Published var sleepAfterMinutes: Int { didSet { store.set(sleepAfterMinutes, forKey: "sleepAfterMinutes") } }
    /// Ads and trackers from third parties are blocked (Shield.swift).
    @Published var blocksAds: Bool {
        didSet {
            store.set(blocksAds, forKey: "blocksAds")
            // Settings change on the main thread; the blocker lives there.
            MainActor.assumeIsolated { Shield.shared.setEnabled(blocksAds) }
        }
    }

    @Published var engine: SearchEngine { didSet { store.set(engine.rawValue, forKey: "engine") } }
    @Published var suggestions: Bool { didSet { store.set(suggestions, forKey: "suggestions") } }
    @Published var restoresTabs: Bool { didSet { store.set(restoresTabs, forKey: "restoresTabs") } }
    /// Offer accounts from Apple's Passwords app (iCloud Keychain) under sign-in fields.
    @Published var applePasswords: Bool { didSet { store.set(applePasswords, forKey: "applePasswords") } }

    private init() {
        store.register(defaults: ["suggestions": true, "restoresTabs": true, "applePasswords": true,
                                  "glassBar": true, "glassWash": 0.25, "cornerRadius": 26.0, "showsLinkPreview": true, "tabPreviews": true,
                                  "autoPiP": true, "sleepsTabs": true, "warmClaude": true, "sleepAfterMinutes": 120, "blocksAds": true])
        theme = Theme(rawValue: store.string(forKey: "theme") ?? "") ?? .system
        glassBar = store.bool(forKey: "glassBar")
        glassWash = store.double(forKey: "glassWash")
        cornerRadius = store.double(forKey: "cornerRadius")
        roundCorners = store.bool(forKey: "roundCorners")
        tabWidth = TabWidth(rawValue: store.string(forKey: "tabWidth") ?? "") ?? .fill
        closeButtons = CloseButtons(rawValue: store.string(forKey: "closeButtons") ?? "") ?? .hover
        showsLinkPreview = store.bool(forKey: "showsLinkPreview")
        showsTabPreviews = store.bool(forKey: "tabPreviews")
        autoPictureInPicture = store.bool(forKey: "autoPiP")
        sleepsTabs = store.bool(forKey: "sleepsTabs")
        keepsClaudeReady = store.bool(forKey: "warmClaude")
        sleepAfterMinutes = store.integer(forKey: "sleepAfterMinutes")
        agentControl = store.bool(forKey: "agentControl")
        remoteConnector = store.bool(forKey: "remoteConnector")
        connectorRelay = store.string(forKey: "connectorRelay") ?? ""
        agentAsk = store.string(forKey: "agentAsk") ?? "auto"
        remoteScripts = store.bool(forKey: "remoteScripts")
        connectorNotBefore = store.double(forKey: "connectorNotBefore")
        blocksAds = store.bool(forKey: "blocksAds")
        engine = SearchEngine(rawValue: store.string(forKey: "engine") ?? "") ?? .google
        suggestions = store.bool(forKey: "suggestions")
        restoresTabs = store.bool(forKey: "restoresTabs")
        applePasswords = store.bool(forKey: "applePasswords")
    }
}

// MARK: - Places on disk

enum Places {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Sill on Chromium keeps its own: both can run side by side.
    static let folder = testProfile.map { "Sill Chromium (\($0))" } ?? "Sill Chromium"

    /// SILL_PROFILE=name runs a separate Sill: its own profile, settings,
    /// session and agent socket, side by side with yours (the agent test course uses it).
    static let testProfile: String? = ProcessInfo.processInfo.environment["SILL_PROFILE"]
        .flatMap { $0.range(of: #"^[A-Za-z0-9-]{1,32}$"#, options: .regularExpression) != nil ? $0 : nil }

    static let caches: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

/// One queue for every saver, made once. (A generic type can't hold a
/// static one, and the computed one it had made a new queue each time.)
private let saveQueue = DispatchQueue(label: "app.sill.save", qos: .utility)

/// Writes a value to disk a moment after the last change, off the main thread.
final class Saver<Value: Encodable> {
    private let url: URL
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?
    private let queue = saveQueue

    init(_ url: URL, delay: TimeInterval = 1) {
        self.url = url
        self.delay = delay
    }

    /// `written` is called on the main thread once the value made is on disk.
    func save(_ make: @escaping () -> Value, written: (@MainActor () -> Void)? = nil) {
        guard !final else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [url, queue] in
            let value = make()
            queue.async {
                guard let data = try? JSONEncoder().encode(value) else { return }
                guard (try? data.write(to: url, options: .atomic)) != nil, let written else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated(written) }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Written at quitting: what the app does as it closes everything down
    /// afterwards (windows closing, tabs going) is not saved over it.
    private var final = false

    /// Right now, on this thread: for quitting. Nothing is saved after it.
    func flush(_ value: Value) {
        final = true
        pending?.cancel()
        pending = nil
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Domains

enum Domains {
    /// Second-level suffixes common enough to matter when telling sites apart.
    private static let twoPart: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "co.jp", "ne.jp", "or.jp", "ac.jp",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "org.nz", "com.br", "com.cn", "com.hk",
        "com.sg", "com.tr", "com.mx", "com.ar", "co.in", "co.za", "co.kr", "com.tw", "com.cy", "com.gr",
        "github.io", "vercel.app", "netlify.app", "pages.dev", "herokuapp.com", "web.app", "firebaseapp.com",
    ]

    static func registrable(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if twoPart.contains(lastTwo) { return labels.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    static func bare(_ host: String?) -> String {
        guard let host = host?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Addresses

enum Address {
    /// What someone typed, read as a web address when it plainly is one.
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        for scheme in ["http://", "https://", "file://", "about:", "data:", "view-source:"] where lower.hasPrefix(scheme) {
            return URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? text)
        }
        guard !text.contains(" ") else { return nil }
        // [::1]:8080/path: an IPv6 address, which only reads as one in brackets.
        if lower.hasPrefix("["), let close = lower.firstIndex(of: "]"), lower[lower.index(after: lower.startIndex)..<close].contains(":"),
           lower[lower.index(after: lower.startIndex)..<close].allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }),
           let url = URL(string: "http://" + text), url.host() != nil { return url }
        // host[:port][/path]
        let hostPart = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
        let hostOnly = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let isLocal = hostOnly == "localhost" || hostOnly.hasSuffix(".localhost") || hostOnly.hasSuffix(".local")
            || hostOnly.hasSuffix(".test")
        let isIP = hostOnly.split(separator: ".").count == 4 && hostOnly.split(separator: ".").allSatisfy { Int($0) != nil }
        let labels = hostOnly.split(separator: ".")
        let tld = labels.last.map(String.init) ?? ""
        let looksLikeDomain = labels.count >= 2 && tld.count >= 2 && tld.allSatisfy(\.isLetter)
            && labels.allSatisfy { !$0.isEmpty }
        guard isLocal || isIP || looksLikeDomain else { return nil }
        let scheme = (isLocal || isIP) ? "http://" : "https://"
        return URL(string: scheme + text)
    }

    /// How an address reads in a list: no scheme, no www, no trailing slash.
    static func display(_ url: URL?) -> String {
        guard let url else { return "" }
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text.removingPercentEncoding ?? text
    }
}
