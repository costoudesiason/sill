import AppKit

/// A page you kept on purpose, apart from history: clearing history never
/// touches it.
struct Bookmark: Codable, Hashable {
    var url: String
    var title: String
    /// The folder it came from in Safari ("Favorites", or one of yours), if any.
    var folder: String?
    var added: Date

    var address: URL? { URL(string: url) }
    var displayTitle: String { title.isEmpty ? Address.display(address) : title }

    /// As a row in ⌘T and ⌘L, which lists visits.
    var asVisit: Visit { Visit(url: url, title: title, count: 1, last: added, typed: 3) }
}

/// Your bookmarks, newest last, in a JSON file beside history. Never written
/// for private windows: those don't add any.
@MainActor
final class Bookmarks {
    static let shared = Bookmarks()
    /// Made yet? Quitting saves it only if so.
    private(set) static var made = false
    static let changed = Notification.Name("SillBookmarksChanged")
    private(set) var list: [Bookmark]
    private var keys: Set<String>
    private static var file: URL { Places.support.appendingPathComponent("bookmarks.json") }
    private let saver = Saver<[Bookmark]>(Bookmarks.file, delay: 0.5)

    private init() {
        let read = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) }
        list = read ?? []
        keys = Set(list.map(\.url))
        Self.made = true
        if read == nil { Self.bringOverImported() }
    }

    func contains(_ url: URL?) -> Bool { url.flatMap(History.key).map(keys.contains) ?? false }

    /// Keeps `url`; false if it was kept already or can't be.
    @discardableResult
    func add(_ url: URL, title: String) -> Bool {
        guard let key = History.key(url), !keys.contains(key) else { return false }
        list.append(Bookmark(url: key, title: title, folder: nil, added: Date()))
        saved()
        return true
    }

    @discardableResult
    func remove(_ url: URL) -> Bookmark? {
        guard let key = History.key(url), let index = list.firstIndex(where: { $0.url == key }) else { return nil }
        let gone = list.remove(at: index)
        saved()
        return gone
    }

    /// Back as it was (Undo), in its old place if it can be.
    func restore(_ bookmark: Bookmark, at index: Int? = nil) {
        guard !keys.contains(bookmark.url) else { return }
        list.insert(bookmark, at: min(index ?? list.count, list.count))
        saved()
    }

    func index(of url: URL) -> Int? {
        History.key(url).flatMap { key in list.firstIndex { $0.url == key } }
    }

    /// Bookmarks from Safari, each once, in Safari's order after yours.
    func merge(_ incoming: [Bookmark]) {
        var added = false
        for mark in incoming where keys.insert(mark.url).inserted {
            list.append(mark)
            added = true
        }
        if added { saved() }
    }

    /// Bookmarks matching every word typed, in their title or address.
    func search(_ text: String, limit: Int) -> [Bookmark] {
        let words = text.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        var result: [Bookmark] = []
        for mark in list.reversed() {
            let title = mark.title.lowercased(), url = mark.url.lowercased()
            guard words.allSatisfy({ title.contains($0) || url.contains($0) }) else { continue }
            result.append(mark)
            if result.count == limit { break }
        }
        return result
    }

    /// The folders, in the order they first appear; nil is the top level.
    var folders: [(name: String?, marks: [Bookmark])] {
        var order: [String?] = []
        var byFolder: [String?: [Bookmark]] = [:]
        for mark in list {
            if byFolder[mark.folder] == nil { order.append(mark.folder) }
            byFolder[mark.folder, default: []].append(mark)
        }
        return order.map { ($0, byFolder[$0] ?? []) }
    }

    func flush() { saver.flush(list) }

    private func saved() {
        keys = Set(list.map(\.url))
        saver.save { [list] in list }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    // MARK: - Safari

    /// Safari's Bookmarks.plist: every bookmark with its folder; the Reading List left out.
    nonisolated static func readSafari(_ file: URL) -> [Bookmark] {
        guard let data = try? Data(contentsOf: file),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var result: [Bookmark] = []
        let now = Date()
        func walk(_ node: [String: Any], folder: String?) {
            if let url = node["URLString"] as? String, url.hasPrefix("http"), let address = URL(string: url),
               let key = History.key(address) {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                result.append(Bookmark(url: key, title: title, folder: folder, added: now))
            }
            guard let children = node["Children"] as? [[String: Any]] else { return }
            let title = node["Title"] as? String
            if title == "com.apple.ReadingList" { return }
            // Safari's own two lists: the bar is Favorites, the menu is the top level.
            let name: String? = switch title {
            case "BookmarksBar": "Favorites"
            case "BookmarksMenu", "", nil: folder
            default: title
            }
            children.forEach { walk($0, folder: name) }
        }
        walk(root, folder: nil)
        return result
    }

    /// Bookmarks imported from Safari before they had a place of their own
    /// went into history: on the first launch with bookmarks, those still in
    /// history come over, read again from Safari with their folders.
    private static func bringOverImported() {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/Bookmarks.plist")
        Task.detached(priority: .utility) {
            let marks = readSafari(file)
            await MainActor.run {
                let visits = History.shared.visits
                var kept = marks.filter { visits[$0.url] != nil }
                // Only if they were imported: then nearly all are in history.
                // A few visited by chance aren't bookmarks you brought over.
                if Double(kept.count) < Double(marks.count) * 0.8 { kept = [] }
                // Written even when empty, so Safari is read for this once only.
                if kept.isEmpty { Bookmarks.shared.saved() } else { Bookmarks.shared.merge(kept) }
            }
        }
    }
}

/// The Bookmarks menu in the menu bar: Add Bookmark, then every bookmark,
/// folders as submenus. Made again only after bookmarks change, so a key
/// press looking through the menus finds it ready.
@MainActor
final class BookmarksMenu: NSObject, NSMenuDelegate {
    static let shared = BookmarksMenu()
    /// Add Bookmark and the line under it: left as they are.
    private let fixed = 2
    private var stale = true
    private var watching: NSObjectProtocol?

    func menuNeedsUpdate(_ menu: NSMenu) {
        if watching == nil {
            watching = NotificationCenter.default.addObserver(forName: Bookmarks.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stale = true }
            }
        }
        guard stale, menu.items.count >= fixed else { return }
        stale = false
        while menu.items.count > fixed { menu.removeItem(at: fixed) }
        let folders = Bookmarks.shared.folders
        menu.items[fixed - 1].isHidden = folders.isEmpty
        for (name, marks) in folders {
            guard let name else { continue }
            let folder = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: name)
            marks.forEach { sub.addItem(Self.item(for: $0)) }
            folder.submenu = sub
            menu.addItem(folder)
        }
        for (name, marks) in folders where name == nil {
            if menu.items.count > fixed { menu.addItem(.separator()) }
            marks.forEach { menu.addItem(Self.item(for: $0)) }
        }
    }

    private static func item(for mark: Bookmark) -> NSMenuItem {
        var title = mark.displayTitle
        if title.count > 60 { title = String(title.prefix(59)) + "…" }
        let item = NSMenuItem(title: title, action: #selector(AppDelegate.openBookmark(_:)), keyEquivalent: "")
        item.target = AppDelegate.shared
        item.representedObject = mark.address
        item.toolTip = Address.display(mark.address)
        return item
    }
}
