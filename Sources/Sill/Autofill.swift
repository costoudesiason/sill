import AppKit
import WebKit

/// Your iCloud Keychain accounts under a sign-in box, the way Safari offers
/// them: the Mac's own menu, opened by a click in the box (or ↓), never
/// filling anything until you pick. Passwords come from Apple's Passwords
/// app through its helper (ApplePasswords.swift); a password is asked for
/// only once you choose its account, and macOS may ask for Touch ID first.
@MainActor
enum Autofill {
    /// Hosts already offered the pairing this session, so it isn't pushed twice.
    private static var offeredPairing: Set<String> = []

    static func offer(for field: LoginField, in tab: Tab, webView: SillWebView, top: CGFloat) {
        // Passwords Sill keeps (saved here, or brought over from Dia) come first.
        guard field.kind == .username || field.kind == .password, let host = webView.url?.host(),
              webView.url?.scheme == "https" || Tab.isLocal(host) else { return offerApple(for: field, in: tab, webView: webView, top: top) }
        Task {
            let saved = await SavedPasswords.logins(for: host)
            guard !saved.isEmpty else { return offerApple(for: field, in: tab, webView: webView, top: top) }
            guard tab.webView === webView, let window = webView.window, window.isKeyWindow else { return }
            // Sill's glass menu, under the box: each account, its site below it.
            let icon = tab.favicon
            let entries: [GlassMenu.Entry] = saved.prefix(8).map { login in
                .item(.init(title: login.user.isEmpty ? "(no name)" : login.user, symbol: "key.fill",
                            subtitle: Domains.bare(login.host), image: icon) {
                    Task {
                        guard let password = await SavedPasswords.password(for: login) else { return }
                        fill(user: login.user, password: password, in: webView)
                    }
                })
            }
            let zoom = webView.pageZoom * webView.magnification
            var point = NSPoint(x: field.rect.minX * zoom, y: top + field.rect.maxY * zoom + 6)
            if !webView.isFlipped { point.y = webView.bounds.height - point.y }
            GlassMenu(title: "Passwords", entries: entries, searchable: false)
                .show(in: window, at: webView.convert(point, to: nil), from: webView)
        }
    }

    private static func offerApple(for field: LoginField, in tab: Tab, webView: SillWebView, top: CGFloat) {
        guard field.kind != .newPassword, Preferences.shared.applePasswords,
              let host = ApplePasswords.offers(on: webView.url, privateTab: tab.isPrivate) else { return }
        let passwords = ApplePasswords.shared
        Task {
            let menu = NSMenu()
            menu.autoenablesItems = false
            switch passwords.state {
            case .paired:
                if field.kind == .code {
                    let codes = await passwords.codes(for: host, tab: tab.id) { tab.webView === webView }
                        .filter { ApplePasswords.belongs([$0.domain], to: host) }
                    guard !codes.isEmpty else { return }
                    menu.addItem(header("Verification Codes"))
                    for code in codes {
                        menu.addItem(item(code.user, subtitle: Domains.bare(code.domain), symbol: "key.viewfinder") {
                            Task {
                                guard let value = await passwords.code(of: code, host: host, tab: tab.id) else { return }
                                fillCode(value, in: webView)
                            }
                        })
                    }
                } else {
                    let logins = ApplePasswords.exactFirst(
                        await passwords.logins(for: host, tab: tab.id) { tab.webView === webView }, to: host)
                    guard !logins.isEmpty else { return }
                    menu.addItem(header("Passwords"))
                    for login in logins.prefix(8) {
                        let site = login.sites.first.map { Domains.bare(Vault.host(of: $0)) } ?? host
                        menu.addItem(item(login.user.isEmpty ? "(no name)" : login.user, subtitle: site, symbol: "key.fill") {
                            Task {
                                guard let found = await passwords.password(for: login.user, host: host, tab: tab.id) else { return }
                                fill(user: login.user, password: found.password, in: webView)
                            }
                        })
                    }
                }
                menu.addItem(.separator())
                menu.addItem(item("Open Passwords", symbol: "key.horizontal") { openPasswordsApp() })
            case .idle:
                guard ApplePasswords.entitled, field.kind != .code, !offeredPairing.contains(host) else { return }
                offeredPairing.insert(host)
                menu.addItem(header("iCloud Passwords"))
                menu.addItem(item("Connect to Apple Passwords…", symbol: "key.icloud") {
                    AppDelegate.shared.showSettings(nil)
                    Task { await ApplePasswords.shared.connect() }
                })
            case .starting, .code, .checking:
                return
            }
            guard tab.webView === webView, webView.window?.isKeyWindow == true else { return }
            show(menu, under: field, in: webView, top: top)
        }
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func item(_ title: String, subtitle: String? = nil, symbol: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: run)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let subtitle { item.subtitle = subtitle }
        return item
    }

    private static func show(_ menu: NSMenu, under field: LoginField, in webView: SillWebView, top: CGFloat) {
        let zoom = webView.pageZoom * webView.magnification
        var point = NSPoint(x: field.rect.minX * zoom, y: top + field.rect.maxY * zoom + 4)
        if !webView.isFlipped { point.y = webView.bounds.height - point.y }
        menu.minimumWidth = max(220, field.rect.width * zoom)
        menu.popUp(positioning: nil, at: point, in: webView)
    }

    private static func fill(user: String, password: String, in webView: SillWebView) {
        webView.callAsyncJavaScript("return window.__sillFill(user, password)", arguments: ["user": user, "password": password],
                                    in: nil, in: Web.world) { _ in }
    }

    private static func fillCode(_ code: String, in webView: SillWebView) {
        webView.callAsyncJavaScript("return window.__sillFillCode(code)", arguments: ["code": code],
                                    in: nil, in: Web.world) { _ in }
    }

    static func openPasswordsApp() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
