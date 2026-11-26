import Foundation

/// What Sill learns from what you do, so an agent knows where to go: the
/// links, buttons, tabs and menu items you click on your sites, and where
/// each one took you. "Open my Travel notebook in OneNote" then needs no
/// clicking around: the page is one you go to, and the way there is known.
///
/// Kept on this Mac only, in a JSON file beside history; never for private
/// windows, never from an agent's own clicks, never anything typed or any
/// field's value: a click's role and visible name, the page it was on (host
/// and path, with ids blurred), and the address it led to. Settings › Agents
/// › Learn from what I do turns it off; Forget clears it.
@MainActor
final class Habits {
    static let shared = Habits()

    struct Click: Codable {
        /// host + path, ids blurred: where it was clicked.
        var page: String
        var role: String
        var name: String
        var count: Int
        var last: Date
        /// Where it led, by address, with how often and the page's title.
        var to: [String: Int] = [:]
        var titles: [String: String] = [:]

        var score: Double { Visit.score(weight: Double(count), since: Date().timeIntervalSince(last)) }
        var destination: (url: String, title: String)? {
            guard let best = to.max(by: { $0.value < $1.value }) else { return nil }
            return (best.key, titles[best.key] ?? "")
        }
    }

    private(set) var clicks: [String: Click] = [:]
    /// A click waiting to see where it goes, per tab.
    private var pending: [ObjectIdentifier: (key: String, at: Date, from: String)] = [:]
    private let saver = Saver<[Click]>(Places.support.appendingPathComponent("habits.json"), delay: 5)
    private static let cap = 4000

    private init() {
        let file = Places.support.appendingPathComponent("habits.json")
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Click].self, from: data) {
            for click in list { clicks[Self.key(click.page, click.role, click.name)] = click }
        }
    }

    var enabled: Bool { Preferences.shared.learnsHabits }

    private static func key(_ page: String, _ role: String, _ name: String) -> String { "\(page)|\(role)|\(name.lowercased())" }

    /// host + path with ids blurred: /notebooks/9f3c…/sections/12345 → /notebooks/*/sections/*.
    static func page(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let parts = url.path.split(separator: "/").prefix(4).map { part -> String in
            let s = String(part)
            let digits = s.filter(\.isNumber).count
            if digits >= 4 || s.count > 24 || (s.count >= 12 && digits * 3 >= s.count) { return "*" }
            return s.lowercased()
        }
        return Domains.bare(host) + "/" + parts.joined(separator: "/")
    }

    /// You clicked something in a page. Not an agent's click (their tabs are skipped).
    func clicked(in tab: Tab, role: String, name: String, href: String?) {
        guard enabled, !tab.isPrivate, !tab.openedByAgent, !AgentActivity.shared.isWorking(on: tab),
              let here = tab.webView?.url, let page = Self.page(here) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { return }
        let key = Self.key(page, role, name)
        var click = clicks[key] ?? Click(page: page, role: role, name: name, count: 0, last: Date())
        click.count += 1
        click.last = Date()
        clicks[key] = click
        // A link says where it goes; a button, or a page that changes its own address, says so in went().
        if let href, let url = URL(string: href), url.host() != nil, History.key(url) != History.key(here) {
            led(key, to: url, title: nil)
            pending[ObjectIdentifier(tab)] = nil
        } else {
            pending[ObjectIdentifier(tab)] = (key, Date(), History.key(here) ?? here.absoluteString)
        }
        trim()
        save()
    }

    /// The tab's address changed (a new page, or a page that changes its own address).
    func went(_ tab: Tab, to url: URL, title: String?) {
        guard let wait = pending[ObjectIdentifier(tab)] else { return }
        guard Date().timeIntervalSince(wait.at) < 8 else { pending[ObjectIdentifier(tab)] = nil; return }
        guard let to = History.key(url), to != wait.from else { return }
        pending[ObjectIdentifier(tab)] = nil
        led(wait.key, to: url, title: title)
        save()
    }

    /// The page's title came after its address.
    func retitle(_ url: URL, _ title: String) {
        guard let to = History.key(url), !title.isEmpty else { return }
        for (key, click) in clicks where click.to[to] != nil && click.titles[to] != title {
            clicks[key]?.titles[to] = title
        }
    }

    private func led(_ key: String, to url: URL, title: String?) {
        guard let to = History.key(url), var click = clicks[key] else { return }
        click.to[to, default: 0] += 1
        if let title, !title.isEmpty { click.titles[to] = title }
        if click.to.count > 4, let least = click.to.min(by: { $0.value < $1.value })?.key {
            click.to[least] = nil; click.titles[least] = nil
        }
        clicks[key] = click
    }

    // MARK: - What agents are told

    /// Your pages on a site (most visited, lately), and what you click there.
    func site(_ host: String, page: URL? = nil, limit: Int = 6) -> [String: Any] {
        // "host:port" is one site: another port on the same machine is another app.
        let parts = host.lowercased().split(separator: ":", maxSplits: 1)
        let bare = Domains.bare(parts.first.map(String.init) ?? host.lowercased()), port = parts.count > 1 ? Int(parts[1]) : nil
        let now = Date()
        let pages = History.shared.visits.values
            .filter { Domains.bare($0.address?.host()) == bare && (port == nil || $0.address?.port == port) && $0.count >= 2 }
            .sorted { $0.score(now: now) > $1.score(now: now) }
            .prefix(limit)
        let here = page.flatMap(Self.page)
        let mine = clicks.values.filter { $0.page.hasPrefix(bare + "/") }
        // Clicks on this very page first, then the site's most used.
        let clicked = mine.sorted { a, b in
            let ah = a.page == here, bh = b.page == here
            return ah != bh ? ah : a.score > b.score
        }.prefix(limit)
        return ["pages": pages.map(Self.describe), "clicks": clicked.map(Self.describe)]
    }

    /// Pages and clicks matching words: "onenote travel", "invoices".
    func search(_ query: String, limit: Int = 12) -> [String: Any] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let now = Date()
        let pages: [Visit]
        if words.isEmpty {
            pages = History.shared.visits.values.filter { $0.count >= 2 }.sorted { $0.score(now: now) > $1.score(now: now) }.prefix(limit).map { $0 }
        } else {
            // History's own search, then ranked by how much you use each page.
            pages = History.shared.search(query, limit: limit * 3).sorted { $0.score(now: now) > $1.score(now: now) }.prefix(limit).map { $0 }
        }
        let clicked = clicks.values.filter { click in
            let hay = ([click.page, click.name] + click.titles.values + click.to.keys).joined(separator: " ").lowercased()
            return !words.isEmpty && words.allSatisfy { hay.contains($0) }
        }.sorted { $0.score > $1.score }.prefix(limit)
        return ["pages": pages.map(Self.describe), "clicks": clicked.map(Self.describe)]
    }

    private static func describe(_ visit: Visit) -> [String: Any] {
        ["url": visit.url, "title": visit.title, "visits": visit.count, "last": ISO8601DateFormatter().string(from: visit.last)]
    }

    private static func describe(_ click: Click) -> [String: Any] {
        var out: [String: Any] = ["page": click.page, "role": click.role, "name": click.name, "times": click.count,
                                  "last": ISO8601DateFormatter().string(from: click.last)]
        if let to = click.destination { out["to"] = to.url; out["toTitle"] = to.title }
        return out
    }

    // MARK: - Kept

    func forget() {
        clicks = [:]
        pending = [:]
        save()
    }

    /// Only for the test course: a click as if you'd made it.
    func record(page url: URL, role: String, name: String, to: URL?, title: String?) {
        guard let page = Self.page(url) else { return }
        let key = Self.key(page, role, name)
        var click = clicks[key] ?? Click(page: page, role: role, name: name, count: 0, last: Date())
        click.count += 1; click.last = Date()
        clicks[key] = click
        if let to { led(key, to: to, title: title) }
        save()
    }

    private func trim() {
        guard clicks.count > Self.cap else { return }
        let keep = clicks.sorted { $0.value.score > $1.value.score }.prefix(Self.cap * 9 / 10)
        clicks = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private func save() {
        saver.save { [clicks] in Array(clicks.values) }
    }
}
