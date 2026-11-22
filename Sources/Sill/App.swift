import AppKit
import SwiftUI
import WebKit

struct SessionTab: Codable {
    var url: String
    var title: String
}

struct SessionWindow: Codable {
    var tabs: [SessionTab]
    var selected: Int
    var frame: String?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private(set) var browsers: [BrowserWindowController] = []
    weak var lastBrowser: BrowserWindowController?
    private var settings: NSWindowController?
    private let session = Saver<[SessionWindow]>(Places.support.appendingPathComponent("session.json"), delay: 0.8)
    private var openedURLsAtLaunch = false
    private var launched = false
    private var themeWatch: Any?
    /// The Mac running short of memory: idle tabs sleep sooner (Settings › Tabs).
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    var current: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? BrowserWindowController)
            ?? lastBrowser ?? browsers.last
    }

    // MARK: - Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        // Before any tab loads: the first loads wait for it (at most a second).
        if Preferences.shared.blocksAds { Shield.shared.compile() }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        _ = ApplePasswords.shared
        NSApp.appearance = Preferences.shared.theme.appearance
        themeWatch = Preferences.shared.$theme.sink { NSApp.appearance = $0.appearance }
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A warning sleeps tabs left for five minutes; critical, every one not in front.
                let critical = self.pressure.data.contains(.critical)
                for browser in self.browsers { browser.napIdleTabs(olderThan: critical ? 0 : 300) }
            }
        }
        pressure.activate()
        if Preferences.shared.restoresTabs, restoreSession() {
            return
        }
        if browsers.isEmpty {
            let browser = makeBrowser(isPrivate: false)
            browser.showWindow(nil)
            browser.showPalette(.newTab)
        }
    }

    private func restoreSession() -> Bool {
        let url = Places.support.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url),
              let windows = try? JSONDecoder().decode([SessionWindow].self, from: data),
              windows.contains(where: { !$0.tabs.isEmpty })
        else { return false }
        for state in windows where !state.tabs.isEmpty {
            let browser = makeBrowser(isPrivate: false)
            if let frame = state.frame { browser.window?.setFrame(from: frame) }
            browser.restore(state.tabs, selectedIndex: state.selected)
            browser.showWindow(nil)
        }
        return !browsers.isEmpty
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        session.flush(sessionState())
        History.shared.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Opening links from other apps

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        open(url)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    private func open(_ url: URL) {
        let browser = current(isPrivate: false) ?? {
            let made = makeBrowser(isPrivate: false)
            made.showWindow(nil)
            return made
        }()
        browser.addTab(url: url)
        browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func current(isPrivate: Bool) -> BrowserWindowController? {
        if let current, current.isPrivate == isPrivate, !current.isPopup { return current }
        return browsers.last { $0.isPrivate == isPrivate && !$0.isPopup }
    }

    // MARK: - Windows

    @discardableResult
    func makeBrowser(isPrivate: Bool, popup: Bool = false) -> BrowserWindowController {
        let browser = BrowserWindowController(isPrivate: isPrivate, popup: popup)
        if popup {
            browsers.append(browser)
            return browser
        }
        if let last = current?.window {
            browser.window?.setFrame(last.frame.offsetBy(dx: 24, dy: -24), display: false)
        } else if !isPrivate {
            browser.window?.setFrameAutosaveName("Sill Browser")
        }
        browser.onChange = { [weak self] in self?.saveSession() }
        browsers.append(browser)
        return browser
    }

    func windowClosed(_ browser: BrowserWindowController) {
        browsers.removeAll { $0 === browser }
        saveSession()
    }

    private func sessionState() -> [SessionWindow] {
        browsers.filter { !$0.isPrivate && !$0.isPopup }.map { browser in
            let tabs = browser.tabs.compactMap { tab -> SessionTab? in
                guard let url = tab.webView?.url ?? tab.url, url.scheme?.hasPrefix("http") == true else { return nil }
                return SessionTab(url: url.absoluteString, title: tab.title)
            }
            let selected = browser.tabs.firstIndex { $0 === browser.selected } ?? 0
            return SessionWindow(tabs: tabs, selected: selected, frame: browser.window?.frameDescriptor)
        }
    }

    private func saveSession() {
        guard launched else { return }
        session.save { [weak self] in self?.sessionState() ?? [] }
    }

    // MARK: - Actions without a window

    @objc func newWindow(_ sender: Any?) {
        let browser = makeBrowser(isPrivate: false)
        browser.showWindow(nil)
        browser.showPalette(.newTab)
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        let browser = makeBrowser(isPrivate: true)
        browser.showWindow(nil)
        browser.showPalette(.newTab)
    }

    /// ⌘T with no window open makes one.
    @objc func newTab(_ sender: Any?) {
        if let current, current.window?.isVisible == true { current.newTab(sender) } else { newWindow(sender) }
    }

    @objc func openLocation(_ sender: Any?) {
        if let current, current.window?.isVisible == true { current.openLocation(sender) } else { newWindow(sender) }
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindow.make() }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all history?"
        alert.informativeText = "Sill forgets every page you have visited. Open tabs, cookies and passwords stay."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { History.shared.clear() }
    }

    @objc func makeDefaultBrowser(_ sender: Any?) {
        let app = Bundle.main.bundleURL
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
        }
    }
}

// MARK: - Menus

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let app = AppDelegate.shared

        main.addItem(submenu("Sill", [
            item("About Sill", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: app),
            item("Make Sill Your Default Browser", #selector(AppDelegate.makeDefaultBrowser(_:)), target: app),
            .separator(),
            item("Clear History…", #selector(AppDelegate.clearHistory(_:)), target: app),
            .separator(),
            servicesItem(),
            .separator(),
            item("Hide Sill", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Sill", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Tab", #selector(AppDelegate.newTab(_:)), "t", target: app),
            item("New Window", #selector(AppDelegate.newWindow(_:)), "n", target: app),
            item("New Private Window", #selector(AppDelegate.newPrivateWindow(_:)), "n", [.command, .shift], target: app),
            item("Open Location…", #selector(AppDelegate.openLocation(_:)), "l", target: app),
            .separator(),
            item("Close Tab", #selector(BrowserWindowController.closeTab(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            item("Reopen Closed Tab", #selector(BrowserWindowController.reopenClosedTab(_:)), "t", [.command, .shift]),
        ]))

        let edit = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Link", #selector(BrowserWindowController.copyPageLink(_:)), "c", [.command, .shift]),
            .separator(),
            item("Find…", #selector(BrowserWindowController.showFind(_:)), "f"),
            item("Find Next", #selector(BrowserWindowController.findNext(_:)), "g"),
            item("Find Previous", #selector(BrowserWindowController.findPrevious(_:)), "g", [.command, .shift]),
        ])
        main.addItem(edit)

        main.addItem(submenu("View", [
            item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"),
            item("Reload Page From Origin", #selector(BrowserWindowController.reloadFromOrigin(_:)), "r", [.command, .option]),
            item("Stop", #selector(BrowserWindowController.stopLoading(_:)), "."),
            .separator(),
            item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"),
            item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "+"),
            hidden(item("Zoom In", #selector(BrowserWindowController.zoomIn(_:)), "=")),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Show All Tabs", #selector(BrowserWindowController.showAllTabs(_:)), "\\", [.command, .shift]),
            item("Downloads", #selector(BrowserWindowController.showDownloads(_:)), "l", [.command, .option]),
            .separator(),
            item("Web Inspector", #selector(BrowserWindowController.showInspector(_:)), "i", [.command, .option]),
        ]))

        main.addItem(submenu("History", [
            item("Back", #selector(BrowserWindowController.goBack(_:)), "["),
            item("Forward", #selector(BrowserWindowController.goForward(_:)), "]"),
            .separator(),
            item("Search History…", #selector(AppDelegate.openLocation(_:)), "y", target: app),
        ]))

        var tabItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Show Next Tab", #selector(BrowserWindowController.nextTab(_:)), "\t", [.control]),
            item("Show Previous Tab", #selector(BrowserWindowController.previousTab(_:)), "\t", [.control, .shift]),
            hidden(item("Show Next Tab", #selector(BrowserWindowController.nextTab(_:)), "]", [.command, .shift])),
            hidden(item("Show Previous Tab", #selector(BrowserWindowController.previousTab(_:)), "[", [.command, .shift])),
            .separator(),
        ]
        for n in 1...9 {
            let menuItem = item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(BrowserWindowController.selectTabByNumber(_:)), "\(n)")
            menuItem.tag = n
            tabItems.append(menuItem)
        }
        tabItems += [.separator(), item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))]
        let window = submenu("Window", tabItems)
        NSApp.windowsMenu = window.submenu
        main.addItem(window)

        let help = submenu("Help", [])
        NSApp.helpMenu = help.submenu
        main.addItem(help)
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    private static func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }
}

