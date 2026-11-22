import AppKit
import SQLite3
import WebKit

/// Brings your Safari over: history (so the palette knows your sites),
/// bookmarks (searchable from ⌘T), cookies (so you stay signed in) and the
/// tabs open in Safari right now. Safari keeps the first three where only
/// apps with Full Disk Access may read; the tabs come by asking Safari.
@MainActor
final class SafariImport: ObservableObject {
    static let shared = SafariImport()

    @Published private(set) var running = false
    @Published private(set) var report: String?

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var historyFile: URL { home.appendingPathComponent("Library/Safari/History.db") }
    private var bookmarksFile: URL { home.appendingPathComponent("Library/Safari/Bookmarks.plist") }
    private var cookiesFile: URL {
        home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
    }

    /// Whether macOS lets Sill read Safari's files.
    var hasAccess: Bool { FileManager.default.isReadableFile(atPath: bookmarksFile.path) && (try? Data(contentsOf: bookmarksFile)) != nil }

    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func run(history: Bool, bookmarks: Bool, cookies: Bool, tabs: Bool) {
        guard !running else { return }
        running = true
        report = nil
        let historyFile = historyFile, bookmarksFile = bookmarksFile, cookiesFile = cookiesFile
        Task.detached(priority: .userInitiated) {
            let visits = history ? Self.readHistory(historyFile) : []
            let marks = bookmarks ? Self.readBookmarks(bookmarksFile) : []
            let jar = cookies ? Self.readCookies(cookiesFile) : []
            await MainActor.run {
                var lines: [String] = []
                if history {
                    History.shared.merge(visits)
                    lines.append("\(visits.count) history entries")
                }
                if bookmarks {
                    History.shared.merge(marks)
                    lines.append("\(marks.count) bookmarks")
                }
                if cookies {
                    let store = WKWebsiteDataStore.default().httpCookieStore
                    store.setCookies(jar) {}
                    lines.append("\(jar.count) cookies")
                }
                if tabs {
                    let opened = Self.openSafariTabs()
                    lines.append(opened >= 0 ? "\(opened) open tabs" : "open tabs (Safari didn't answer)")
                }
                let unreadable = (history && visits.isEmpty) || (cookies && jar.isEmpty) || (bookmarks && marks.isEmpty)
                self.report = "Imported " + lines.joined(separator: ", ") + "."
                    + (unreadable && !self.hasAccess ? " Some files need Full Disk Access." : "")
                self.running = false
            }
        }
    }

    // MARK: - History

    nonisolated private static func readHistory(_ file: URL) -> [Visit] {
        var db: OpaquePointer?
        let path = "file:\(file.path)?immutable=1"
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT i.url, COALESCE(v.title, ''), i.visit_count, MAX(v.visit_time)
        FROM history_items i JOIN history_visits v ON v.history_item = i.id
        GROUP BY i.id ORDER BY MAX(v.visit_time) DESC LIMIT 5000
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result: [Visit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let url = String(cString: raw)
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let count = Int(sqlite3_column_int(statement, 2))
            let time = sqlite3_column_double(statement, 3)
            result.append(Visit(url: url, title: title, count: max(1, count), last: Date(timeIntervalSinceReferenceDate: time)))
        }
        return result
    }

    // MARK: - Bookmarks

    nonisolated private static func readBookmarks(_ file: URL) -> [Visit] {
        guard let data = try? Data(contentsOf: file),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var result: [Visit] = []
        func walk(_ node: [String: Any]) {
            if let url = node["URLString"] as? String, url.hasPrefix("http") {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                // A bookmark counts as a site you chose: typed, so it ranks well.
                result.append(Visit(url: url, title: title, count: 1, last: Date(timeIntervalSinceNow: -86_400 * 7), typed: 3))
            }
            (node["Children"] as? [[String: Any]])?.forEach(walk)
        }
        walk(root)
        return result
    }

    // MARK: - Cookies

    /// Safari's Cookies.binarycookies: big-endian page table, little-endian pages.
    nonisolated private static func readCookies(_ file: URL) -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: file), data.count > 8,
              data.prefix(4) == Data("cook".utf8) else { return [] }
        let bytes = [UInt8](data)
        func be32(_ at: Int) -> Int { at + 4 <= bytes.count ? Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3]) : 0 }
        func le32(_ at: Int) -> Int { at + 4 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 : 0 }
        func le64double(_ at: Int) -> Double {
            guard at + 8 <= bytes.count else { return 0 }
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(bytes[at + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: raw)
        }
        func string(_ at: Int) -> String {
            guard at < bytes.count, let end = bytes[at...].firstIndex(of: 0) else { return "" }
            return String(decoding: bytes[at..<end], as: UTF8.self)
        }

        let pages = be32(4)
        var sizes: [Int] = []
        for i in 0..<pages { sizes.append(be32(8 + i * 4)) }
        var offset = 8 + pages * 4
        var cookies: [HTTPCookie] = []
        let now = Date()
        for size in sizes {
            let page = offset
            offset += size
            guard page + 8 <= bytes.count else { break }
            let count = le32(page + 4)
            for c in 0..<count {
                let start = page + le32(page + 8 + c * 4)
                guard start + 56 <= bytes.count else { continue }
                let flags = le32(start + 8)
                let domain = string(start + le32(start + 16))
                let name = string(start + le32(start + 20))
                let path = string(start + le32(start + 24))
                let value = string(start + le32(start + 28))
                let expiry = Date(timeIntervalSinceReferenceDate: le64double(start + 40))
                guard !domain.isEmpty, !name.isEmpty, expiry > now else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [
                    .domain: domain, .name: name, .value: value, .path: path.isEmpty ? "/" : path, .expires: expiry,
                ]
                if flags & 1 != 0 { properties[.secure] = "TRUE" }
                if flags & 4 != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
                if let cookie = HTTPCookie(properties: properties) { cookies.append(cookie) }
            }
        }
        return cookies
    }

    // MARK: - Open tabs

    /// Asks Safari for the address of every open tab (macOS asks you first)
    /// and opens them here. -1 if Safari wouldn't say.
    private static func openSafariTabs() -> Int {
        let source = """
        tell application "Safari"
            set out to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set end of out to (URL of t as text)
                end repeat
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let list = NSAppleScript(source: source)?.executeAndReturnError(&error), error == nil else { return -1 }
        var urls: [URL] = []
        if list.numberOfItems > 0 {
            for i in 1...list.numberOfItems {
                if let text = list.atIndex(i)?.stringValue, let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
                    urls.append(url)
                }
            }
        }
        guard !urls.isEmpty else { return 0 }
        let browser = AppDelegate.shared.current ?? AppDelegate.shared.makeBrowser(isPrivate: false)
        // Opened asleep: they load when you click them, not all at once.
        for url in urls { browser.appendSleeping(url) }
        browser.showWindow(nil)
        return urls.count
    }
}
