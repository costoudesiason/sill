import AppKit
@preconcurrency import UserNotifications
import WebKit

// MARK: - What sites may do

/// What you've answered when a site asked for the camera, the microphone,
/// where you are, or to send notifications, and the plain-HTTP sites you
/// chose to carry on to.
///
/// "Allow" is kept until it is reset; "Allow for One Day" until a day has
/// passed; "Don't Allow" and "Continue" until Sill quits. What is kept is in
/// the app's defaults, which are in memory from launch: nothing is read for
/// it. Private windows have answers of their own, in memory only, gone with
/// the last of them.
@MainActor
final class SitePermissions {
    static let shared = SitePermissions()

    enum Kind: String { case camera, microphone, location, notifications, insecure }
    enum Lasting { case run, day, always }

    private struct Answer {
        var allowed: Bool
        var until: Date?
    }

    private static let defaultsKey = "sitePermissions"
    /// Allowed and kept: "kind site" to when it ends, 0 for never.
    private var kept: [String: Double]
    private var thisRun: [String: Answer] = [:]
    private var inPrivate: [String: Answer] = [:]

    private init() {
        kept = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Double]) ?? [:]
    }

    /// A site as WebKit names it: scheme, host, and port if it isn't the usual one.
    static func site(_ origin: WKSecurityOrigin) -> String {
        "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
    }

    private func answer(_ kind: Kind, _ site: String, private isPrivate: Bool) -> Bool? {
        let key = "\(kind.rawValue) \(site)"
        if isPrivate {
            guard let answer = inPrivate[key] else { return nil }
            if let until = answer.until, until < Date() { inPrivate[key] = nil; return nil }
            return answer.allowed
        }
        if let until = kept[key] {
            if until == 0 || until > Date().timeIntervalSince1970 { return true }
            kept[key] = nil
            save()
        }
        return thisRun[key]?.allowed
    }

    /// True if `site` may use all of `kinds`, false if it was refused one, nil if it hasn't been answered.
    func allowed(_ kinds: [Kind], at site: String, private isPrivate: Bool) -> Bool? {
        let answers = kinds.map { answer($0, site, private: isPrivate) }
        if answers.contains(false) { return false }
        return answers.contains(nil) ? nil : true
    }

    func set(_ kinds: [Kind], at site: String, allowed: Bool, lasting: Lasting, private isPrivate: Bool) {
        let until = lasting == .day ? Date().addingTimeInterval(86400) : nil
        for kind in kinds {
            let key = "\(kind.rawValue) \(site)"
            if isPrivate {
                inPrivate[key] = Answer(allowed: allowed, until: until)
            } else if allowed, lasting != .run {
                kept[key] = until?.timeIntervalSince1970 ?? 0
                thisRun[key] = nil
            } else {
                kept[key] = nil
                thisRun[key] = Answer(allowed: allowed, until: nil)
            }
        }
        if !isPrivate { save() }
    }

    private func save() {
        UserDefaults.standard.set(kept, forKey: Self.defaultsKey)
    }

    /// The last private window closed.
    func forgetPrivate() { inPrivate = [:] }

    /// Every site asks again.
    func reset() {
        kept = [:]
        thisRun = [:]
        inPrivate = [:]
        save()
    }

    /// Whether any site is allowed to send notifications from an earlier run.
    var keepsNotifications: Bool { kept.keys.contains { $0.hasPrefix(Kind.notifications.rawValue + " ") } }

    /// For WebKit, which tells each page what `Notification.permission` is:
    /// the sites answered either way, outside private windows.
    var notificationAnswers: [String: NSNumber] {
        var answers: [String: NSNumber] = [:]
        let prefix = Kind.notifications.rawValue + " "
        for key in Set(kept.keys).union(thisRun.keys) where key.hasPrefix(prefix) {
            let site = String(key.dropFirst(prefix.count))
            if let allowed = answer(.notifications, site, private: false) { answers[site] = NSNumber(value: allowed) }
        }
        return answers
    }

    /// Whether you chose to carry on to `host` over plain HTTP, or to a
    /// site it is a subdomain of (one that hops between its subdomains
    /// asks once). Never by a guess at where the registered name ends:
    /// two unrelated sites under one suffix don't share an answer.
    func continuesOverHTTP(to host: String, private isPrivate: Bool) -> Bool {
        var labels = host.lowercased().split(separator: ".")[...]
        while labels.count >= 2 {
            if allowed([.insecure], at: labels.joined(separator: "."), private: isPrivate) == true { return true }
            labels = labels.dropFirst()
        }
        return false
    }

    /// Plain HTTP to this host is something to ask about. Not this Mac, an
    /// address by number, or a name on the local network: those loaded
    /// before without a word, and there is no certificate they could have.
    static func asksBeforeHTTP(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        if !host.contains(".") || host.contains(":") { return false }
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) { return false }
        return true
    }
}

// MARK: - The question

/// One question for the person at the page: what it says, the answers on
/// offer (the last is the one a Return would mean), and what to do with the
/// one picked. `choice` is nil if the page went away before any was;
/// `picked` is false when an earlier answer settled it.
final class SiteAsk {
    let symbol: String
    let title: String
    let detail: String?
    let choices: [String]
    /// Holds a page that hasn't loaded yet (the plain-HTTP question).
    let holdsNavigation: Bool
    /// An answer given since it was asked, if there is one.
    let known: (() -> Int?)?
    let answer: (_ choice: Int?, _ picked: Bool) -> Void

    init(symbol: String, title: String, detail: String? = nil, choices: [String], holdsNavigation: Bool = false,
         known: (() -> Int?)? = nil, answer: @escaping (_ choice: Int?, _ picked: Bool) -> Void) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.choices = choices
        self.holdsNavigation = holdsNavigation
        self.known = known
        self.answer = answer
    }
}

/// The card a question is shown on, top right of its page. Glass, like the
/// toast and the find bar, and laid out plainly: a symbol, a line or two of
/// text, and a row of buttons.
final class SitePrompt: NSView {
    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var choose: ((Int) -> Void)?
    private(set) weak var ask: SiteAsk?

    private static let width: CGFloat = 348

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glass.cornerRadius = 20
        glass.contentView = content
        addSubview(glass)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        content.addSubview(icon)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.maximumNumberOfLines = 3
        content.addSubview(titleLabel)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        content.addSubview(detailLabel)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ ask: SiteAsk, choose: @escaping (Int) -> Void) {
        self.ask = ask
        self.choose = choose
        icon.image = NSImage(systemSymbolName: ask.symbol, accessibilityDescription: nil)
        titleLabel.stringValue = ask.title
        detailLabel.stringValue = ask.detail ?? ""
        detailLabel.isHidden = ask.detail == nil
        setAccessibilityLabel(ask.title)
        buttons.forEach { $0.removeFromSuperview() }
        buttons = ask.choices.enumerated().map { index, title in
            let button = NSButton(title: title, target: self, action: #selector(picked(_:)))
            button.bezelStyle = .glass
            button.controlSize = .small
            button.tag = index
            content.addSubview(button)
            return button
        }
        layOut()
    }

    private func layOut() {
        let width = Self.width, edge: CGFloat = 14, textX: CGFloat = 42
        let textWidth = width - textX - edge
        var y: CGFloat = 12
        for label in [titleLabel, detailLabel] where !label.isHidden {
            let height = label.sizeThatFits(NSSize(width: textWidth, height: 200)).height
            label.frame = NSRect(x: textX, y: y, width: textWidth, height: height)
            y += height + 3
        }
        icon.frame = NSRect(x: edge, y: 10, width: 20, height: 20)
        y += 8
        // Right to left, so the last answer sits at the right edge.
        var x = width - edge
        var rowHeight: CGFloat = 0
        for button in buttons.reversed() {
            button.sizeToFit()
            x -= button.frame.width
            button.frame.origin = NSPoint(x: x, y: y)
            x -= 6
            rowHeight = max(rowHeight, button.frame.height)
        }
        setFrameSize(NSSize(width: width, height: y + rowHeight + 12))
        glass.frame = bounds
        content.frame = glass.bounds
    }

    /// Top right of `page`, a rectangle in `stage`.
    func place(over page: NSRect, in stage: NSView, down: CGFloat = 0) {
        if superview !== stage {
            stage.addSubview(self)
            alphaValue = 0
            Motion.animate(Motion.quick) { animator().alphaValue = 1 }
        }
        frame.origin = NSPoint(x: max(page.minX + 8, page.maxX - frame.width - 14), y: page.minY + 10 + down)
    }

    @objc private func picked(_ sender: NSButton) { choose?(sender.tag) }
}

// MARK: - Notifications from pages

/// `new Notification(…)` in a page, shown as one of the Mac's own
/// notifications; clicking it brings its tab to the front and tells the page.
///
/// WebKit hands an app's pages no way to show one unless the app gives it a
/// "provider", through the C interface Safari uses; its functions are looked
/// up by name, and without them pages are simply never shown as allowed.
/// Nothing is set up until some site is allowed to notify.
@MainActor
final class PageNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PageNotifications()
    private var installed = false
    private var manager: UnsafeRawPointer?
    private var tabs: [UInt64: () -> Tab?] = [:]

    private static let webKit = dlopen(nil, RTLD_NOW)
    private static func function<T>(_ name: String, _ type: T.Type) -> T? {
        dlsym(webKit, name).map { unsafeBitCast($0, to: type) }
    }
    private typealias Getter = @convention(c) (UnsafeRawPointer) -> UnsafeRawPointer?
    private typealias Identifier = @convention(c) (UnsafeRawPointer) -> UInt64
    private typealias Told = @convention(c) (UnsafeRawPointer, UInt64) -> Void
    private typealias Shown = @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, UnsafeRawPointer?) -> Void
    private typealias Withdrawn = @convention(c) (UnsafeRawPointer, UnsafeRawPointer?) -> Void

    /// Whether pages can be shown notifications at all on this WebKit.
    var available: Bool {
        Self.function("WKContextGetNotificationManager", Getter.self) != nil
            && Self.function("WKNotificationManagerSetProvider", (@convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void).self) != nil
            && Self.function("WKNotificationGetID", Identifier.self) != nil
    }

    func install() {
        guard !installed, available else { return }
        installed = true
        // Pages are told what was answered for their site (Notification.permission).
        let setDelegate = NSSelectorFromString("set_delegate:")
        if WKWebsiteDataStore.default().responds(to: setDelegate) { WKWebsiteDataStore.default().perform(setDelegate, with: self) }
        guard let manager = Self.function("WKContextGetNotificationManager", Getter.self)?(Unmanaged.passUnretained(Web.pool).toOpaque()),
              let set = Self.function("WKNotificationManagerSetProvider", (@convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Void).self)
        else { return }
        self.manager = manager
        // WebKit's provider struct, version 0: a version, a context, then its
        // callbacks, show and cancel first. WebKit copies it.
        let show: Shown = { page, notification, _ in
            MainActor.assumeIsolated { PageNotifications.shared.show(notification, from: page) }
        }
        let cancel: Withdrawn = { notification, _ in
            MainActor.assumeIsolated { PageNotifications.shared.withdraw(notification) }
        }
        let provider = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 16)
        provider.initialize(repeating: nil, count: 16)
        provider[2] = unsafeBitCast(show, to: UnsafeRawPointer.self)
        provider[3] = unsafeBitCast(cancel, to: UnsafeRawPointer.self)
        set(manager, UnsafeRawPointer(provider))
        provider.deallocate()
    }

    @objc(notificationPermissionsForWebsiteDataStore:)
    func notificationPermissions(for store: WKWebsiteDataStore) -> [String: NSNumber] {
        SitePermissions.shared.notificationAnswers
    }

    private static func text(_ name: String, of notification: UnsafeRawPointer) -> String {
        typealias Copy = @convention(c) (CFAllocator?, UnsafeRawPointer) -> Unmanaged<CFString>?
        guard let string = function(name, Getter.self)?(notification) else { return "" }
        defer { function("WKRelease", (@convention(c) (UnsafeRawPointer) -> Void).self)?(string) }
        return (function("WKStringCopyCFString", Copy.self)?(nil, string)?.takeRetainedValue() as String?) ?? ""
    }

    private static func tab(showing page: UnsafeRawPointer) -> Tab? {
        let selector = NSSelectorFromString("_pageRefForTransitionToWKWebView")
        typealias PageRef = @convention(c) (AnyObject, Selector) -> UnsafeRawPointer?
        for browser in AppDelegate.shared.browsers {
            for tab in browser.tabs {
                guard let view = tab.webView, view.responds(to: selector) else { continue }
                if unsafeBitCast(view.method(for: selector), to: PageRef.self)(view, selector) == page { return tab }
            }
        }
        return nil
    }

    private func show(_ notification: UnsafeRawPointer, from page: UnsafeRawPointer?) {
        guard let manager, let id = Self.function("WKNotificationGetID", Identifier.self)?(notification) else { return }
        let tab = page.flatMap(Self.tab)
        // Nothing from a private window is left in Notification Centre.
        if tab?.isPrivate == true { return }
        // Still allowed: a page open since before a reset, or since its day
        // ran out, has WebKit's word that it may notify, and no longer yours.
        guard let site = Self.site(of: notification) ?? tab?.webView?.url.flatMap(Self.site),
              SitePermissions.shared.allowed([.notifications], at: site, private: false) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = Self.text("WKNotificationCopyTitle", of: notification)
        content.body = Self.text("WKNotificationCopyBody", of: notification)
        if let host = tab?.url?.host() { content.subtitle = Domains.bare(host) }
        content.userInfo = ["page": NSNumber(value: id)]
        if tabs.count > 200 { tabs = [:] }
        tabs[id] = { [weak tab] in tab }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // The Mac asks once whether Sill may notify at all.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "page-\(id)", content: content, trigger: nil))
            // The page hears it was shown only once the Mac has let it be.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let manager = PageNotifications.shared.manager else { return }
                    Self.function("WKNotificationManagerProviderDidShowNotification", Told.self)?(manager, id)
                }
            }
        }
    }

    /// The site a notification is from, as SitePermissions names sites.
    private static func site(of notification: UnsafeRawPointer) -> String? {
        typealias Copy = @convention(c) (CFAllocator?, UnsafeRawPointer) -> Unmanaged<CFString>?
        guard let origin = function("WKNotificationGetSecurityOrigin", Getter.self)?(notification),
              let string = function("WKSecurityOriginCopyToString", Getter.self)?(origin) else { return nil }
        defer { function("WKRelease", (@convention(c) (UnsafeRawPointer) -> Void).self)?(string) }
        return function("WKStringCopyCFString", Copy.self)?(nil, string)?.takeRetainedValue() as String?
    }

    private static func site(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    private func withdraw(_ notification: UnsafeRawPointer) {
        guard let id = Self.function("WKNotificationGetID", Identifier.self)?(notification) else { return }
        tabs[id] = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["page-\(id)"])
    }

    /// Shown even while Sill is in front: the page that sent it may be a tab behind.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["page"] as? NSNumber)?.uint64Value
        let clicked = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard clicked, let id, let manager = self.manager else { return }
                Self.function("WKNotificationManagerProviderDidClickNotification", Told.self)?(manager, id)
                if let tab = self.tabs.removeValue(forKey: id)?() {
                    NSApp.activate()
                    tab.host?.bringBack(tab)
                }
            }
        }
        completionHandler()
    }
}
