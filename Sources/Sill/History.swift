import Foundation

/// Where you have been, kept small: one entry per address, how often and how
/// lately, in a JSON file beside the session. Never written for private windows.
struct Visit: Codable, Hashable {
    var url: String
    var title: String
    var count: Int
    var last: Date
    /// Times it was typed or picked in the palette, which says more than a link click.
    var typed: Int = 0

    var address: URL? { URL(string: url) }

    /// Frecency: how often, weighted by how recently.
    func score(now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(last) / 86_400)
        let recency: Double = days < 1 ? 1 : days < 4 ? 0.7 : days < 14 ? 0.5 : days < 31 ? 0.3 : days < 90 ? 0.15 : 0.05
        return (Double(count) + Double(typed) * 2) * recency
    }
}

@MainActor
final class History {
    static let shared = History()
    private(set) var visits: [String: Visit] = [:] { didSet { knownHosts = nil; shelf = nil; latest = nil } }
    private var knownHosts: Set<String>?
    /// The last answer to `recent`, kept until history changes: the empty
    /// palette asks each time it is shown or its field is cleared, and each
    /// answer is a sort of everything.
    private var latest: (limit: Int, visits: [Visit])?
    /// Five seconds: a page changing its title or address in a burst is one write, not many.
    private let saver = Saver<[Visit]>(Places.support.appendingPathComponent("history.json"), delay: 5)
    private static let cap = 6000

    private init() {
        let url = Places.support.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Visit].self, from: data) {
            visits = Dictionary(list.map { ($0.url, $0) }, uniquingKeysWith: { a, b in a.last > b.last ? a : b })
        }
    }

    static func key(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var text = components?.string ?? url.absoluteString
        if text.hasSuffix("/") && components?.path == "/" { text.removeLast() }
        return text
    }

    func record(_ url: URL, title: String?, typed: Bool = false) {
        guard let key = Self.key(url) else { return }
        var visit = visits[key] ?? Visit(url: key, title: "", count: 0, last: Date())
        visit.count += 1
        visit.last = Date()
        if typed { visit.typed += 1 }
        if let title, !title.isEmpty { visit.title = title }
        visits[key] = visit
        trim()
        persist()
    }

    func retitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, let key = Self.key(url), visits[key] != nil, visits[key]?.title != title else { return }
        visits[key]?.title = title
        persist()
    }

    /// Entries from elsewhere (Safari), kept alongside your own: the more
    /// visited and the later, whichever has more.
    func merge(_ list: [Visit]) {
        for item in list {
            guard let url = URL(string: item.url), let key = Self.key(url) else { continue }
            if var mine = visits[key] {
                mine.count = max(mine.count, item.count)
                mine.typed = max(mine.typed, item.typed)
                if item.last > mine.last { mine.last = item.last }
                if mine.title.isEmpty { mine.title = item.title }
                visits[key] = mine
            } else {
                var copy = item
                copy.url = key
                visits[key] = copy
            }
        }
        trim()
        persist()
    }

    func remove(_ key: String) {
        visits[key] = nil
        persist()
    }

    func markTyped(_ url: URL) {
        guard let key = Self.key(url) else { return }
        visits[key]?.typed += 1
    }

    func clear() {
        visits = [:]
        persist()
    }

    /// What searching needs of an entry, worked out once rather than on every
    /// keystroke: parsing and lowercasing six thousand addresses is most of
    /// what a search costs.
    private struct Reading {
        /// The host and path, not the query: a search page's parameters
        /// would otherwise match almost anything.
        let path: String
        let bare: String
        let depth: Double
        let rawHost: String?
        let host: String
        let title: String
        let lowerTitle: String
        /// The same text as bytes: looking for a word in six thousand
        /// entries is a memory search, not six thousand string comparisons.
        let pathBytes: ContiguousArray<UInt8>
        let titleBytes: ContiguousArray<UInt8>
        let hostBytes: ContiguousArray<UInt8>
        let rawHostBytes: ContiguousArray<UInt8>
        let bareBytes: ContiguousArray<UInt8>
    }
    private var readings: [String: Reading] = [:]
    /// Every entry beside its reading, in a row: made once after history
    /// changes, then walked on each keystroke without a lookup per entry.
    private var shelf: [(Visit, Reading)]?

    private var entries: [(Visit, Reading)] {
        if let shelf { return shelf }
        let made = visits.values.map { ($0, reading($0)) }
        shelf = made
        return made
    }

    private static func bytes(_ text: String) -> ContiguousArray<UInt8> {
        // One spelling of each accented letter, as comparing strings would see it.
        ContiguousArray(text.precomposedStringWithCanonicalMapping.utf8)
    }

    private static func has(_ hay: ContiguousArray<UInt8>, _ needle: ContiguousArray<UInt8>) -> Bool {
        guard needle.count <= hay.count else { return false }
        return hay.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
        }
    }

    private static func starts(_ hay: ContiguousArray<UInt8>, _ prefix: ContiguousArray<UInt8>) -> Bool {
        guard prefix.count <= hay.count else { return false }
        return hay.withUnsafeBytes { h in
            prefix.withUnsafeBytes { p in memcmp(h.baseAddress, p.baseAddress, p.count) == 0 }
        }
    }

    private func reading(_ visit: Visit) -> Reading {
        if let known = readings[visit.url], known.title == visit.title { return known }
        if readings.count > Self.cap * 2 { readings = [:] }
        let url = visit.address
        let bare = Address.display(url).lowercased()
        let rawHost = url?.host()?.lowercased()
        let path = url.map { (($0.host() ?? "") + $0.path).lowercased() } ?? visit.url.lowercased()
        let host = Domains.bare(rawHost)
        let lowerTitle = visit.title.lowercased()
        let made = Reading(path: path,
                           bare: bare,
                           depth: Double(1 + bare.utf8.reduce(0) { $1 == 47 ? $0 + 1 : $0 }) * 0.5 + 0.5,
                           rawHost: rawHost,
                           host: host,
                           title: visit.title,
                           lowerTitle: lowerTitle,
                           pathBytes: Self.bytes(path),
                           titleBytes: Self.bytes(lowerTitle),
                           hostBytes: Self.bytes(host),
                           rawHostBytes: Self.bytes(rawHost ?? ""),
                           bareBytes: Self.bytes(bare))
        readings[visit.url] = made
        return made
    }

    /// Entries matching every word typed, best first.
    func search(_ text: String, limit: Int) -> [Visit] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let now = Date()
        var scored: [(Visit, Reading, Double)] = []
        let needles = words.map(Self.bytes)
        for (visit, read) in entries {
            guard needles.allSatisfy({ Self.has(read.pathBytes, $0) || Self.has(read.titleBytes, $0) }) else { continue }
            var score = visit.score(now: now)
            if read.bare.hasPrefix(words[0]) { score *= 4 }
            else if read.lowerTitle.hasPrefix(words[0]) { score *= 2 }
            // Prefer the site's front page over a deep link of equal weight.
            score /= read.depth
            scored.append((visit, read, score))
        }
        scored.sort { $0.2 > $1.2 }
        // One entry per page as it reads: www and trailing slashes don't make another.
        var seen = Set<String>()
        var result: [Visit] = []
        for (visit, read, _) in scored {
            guard seen.insert(read.bare + "\u{1}" + visit.title).inserted, seen.insert(read.bare).inserted else { continue }
            result.append(visit)
            if result.count == limit { break }
        }
        return result
    }

    /// Whether you've been to this site before (www or not).
    func knows(host: String) -> Bool {
        let bare = Domains.bare(host)
        if knownHosts == nil { knownHosts = Set(visits.values.compactMap { $0.address.map { Domains.bare($0.host()) } }) }
        return knownHosts?.contains(bare) ?? false
    }

    /// Lately visited, one per address.
    func recent(limit: Int) -> [Visit] {
        if let latest, latest.limit == limit { return latest.visits }
        let made = Array(visits.values.sorted { $0.last > $1.last }.prefix(limit))
        latest = (limit, made)
        return made
    }

    /// Most visited sites, one per host.
    func top(limit: Int) -> [Visit] {
        var best: [String: Visit] = [:]
        let now = Date()
        for visit in visits.values {
            let host = Domains.bare(visit.address?.host())
            if let current = best[host], current.score(now: now) >= visit.score(now: now) { continue }
            best[host] = visit
        }
        return Array(best.values.sorted { $0.score(now: now) > $1.score(now: now) }.prefix(limit))
    }

    /// What the address field should finish `typed` with: the rest of a host
    /// (or host and path) you have been to, as Safari does inline.
    func completion(for typed: String) -> String? {
        let prefix = typed.lowercased()
        guard prefix.count >= 1, !prefix.contains(" ") else { return nil }
        let now = Date()
        var best: (String, Double)?
        let deep = prefix.contains("/")
        let start = Self.bytes(prefix)
        for (visit, read) in entries {
            guard let rawHost = read.rawHost else { continue }
            let host = read.host
            // Bytes first: nearly every entry is turned away here.
            guard Self.starts(read.hostBytes, start) || Self.starts(read.rawHostBytes, start)
                    || (deep && Self.starts(read.bareBytes, start)) else { continue }
            for candidate in deep ? [host, rawHost, read.bare] : [host, rawHost]
            where candidate.hasPrefix(prefix) && candidate.count > prefix.count {
                let score = visit.score(now: now) + (candidate == host ? 0.5 : 0)
                if best == nil || score > best!.1 { best = (candidate, score) }
            }
        }
        return best?.0
    }

    private func trim() {
        guard visits.count > Self.cap else { return }
        let keep = visits.values.sorted { $0.last > $1.last }.prefix(Self.cap * 9 / 10)
        visits = Dictionary(keep.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func persist() {
        saver.save { [weak self] in self.map { Array($0.visits.values) } ?? [] }
    }

    func flush() { saver.flush(Array(visits.values)) }
}
