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
        Self.score(weight: Double(count) + Double(typed) * 2, since: now.timeIntervalSince(last))
    }

    /// The same sum from its parts, for a search that keeps them side by side.
    static func score(weight: Double, since seconds: TimeInterval) -> Double {
        let days = max(0, seconds / 86_400)
        let recency: Double = days < 1 ? 1 : days < 4 ? 0.7 : days < 14 ? 0.5 : days < 31 ? 0.3 : days < 90 ? 0.15 : 0.05
        return weight * recency
    }
}

@MainActor
final class History {
    static let shared = History()
    private(set) var visits: [String: Visit] = [:] { didSet { knownHosts = nil; shelf = nil; flat = nil; latest = nil } }
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

    /// The shelf's bytes end to end, and where each entry's lie: a keystroke
    /// walks this one run of memory and touches an entry only if it matches,
    /// where walking the shelf itself copies every entry to look at it.
    private struct Flat {
        /// Five to an entry: path, title, host, raw host, bare. Each a start and a length.
        static let path = 0, title = 1, host = 2, rawHost = 3, bare = 4, fields = 5
        var bytes = ContiguousArray<UInt8>()
        var spans = ContiguousArray<Int32>()
        /// Three to an entry, what its score is made of: visits counted, when last, how deep.
        var weights = ContiguousArray<Double>()
    }
    private var flat: Flat?

    private func flattened(_ entries: [(Visit, Reading)]) -> Flat {
        if let flat { return flat }
        var made = Flat()
        made.spans.reserveCapacity(entries.count * Flat.fields * 2)
        for (visit, read) in entries {
            made.weights.append(Double(visit.count) + Double(visit.typed) * 2)
            made.weights.append(visit.last.timeIntervalSinceReferenceDate)
            made.weights.append(read.depth)
            for field in [read.pathBytes, read.titleBytes, read.hostBytes, read.rawHostBytes, read.bareBytes] {
                made.spans.append(Int32(made.bytes.count))
                made.spans.append(Int32(field.count))
                made.bytes.append(contentsOf: field)
            }
        }
        flat = made
        return made
    }

    private static func bytes(_ text: String) -> ContiguousArray<UInt8> {
        // One spelling of each accented letter, as comparing strings would see it.
        ContiguousArray(text.precomposedStringWithCanonicalMapping.utf8)
    }

    /// The words' bytes held still for as long as `body` looks at them: one
    /// run of memory however many words there are.
    private static func pointers(to words: [ContiguousArray<UInt8>], _ body: ([UnsafeRawBufferPointer]) -> Void) {
        var all = ContiguousArray<UInt8>()
        for word in words { all.append(contentsOf: word) }
        all.withUnsafeBytes { all in
            var start = 0
            body(words.map { word in
                defer { start += word.count }
                return UnsafeRawBufferPointer(rebasing: all[start..<start + word.count])
            })
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
        // A score and a place on the shelf for each match, in shelf order.
        var scored: [(score: Double, at: Int)] = []
        let needles = words.map(Self.bytes)
        let entries = entries
        let flat = flattened(entries)
        var result: [Visit] = []
        entries.withUnsafeBufferPointer { entries in
            flat.bytes.withUnsafeBufferPointer { bytes in
                flat.spans.withUnsafeBufferPointer { spans in
                    Self.pointers(to: needles) { needles in
                        func has(_ at: Int, _ field: Int, _ needle: UnsafeRawBufferPointer) -> Bool {
                            let span = (at * Flat.fields + field) * 2
                            let count = Int(spans[span + 1])
                            guard needle.count <= count else { return false }
                            return memmem(bytes.baseAddress! + Int(spans[span]), count, needle.baseAddress, needle.count) != nil
                        }
                        // A plain word can only begin text whose bytes begin with it, so
                        // the bytes turn most entries away before a string is compared.
                        let plain = needles[0].allSatisfy { $0 < 0x80 }
                        func begins(_ at: Int, _ field: Int) -> Bool {
                            let span = (at * Flat.fields + field) * 2
                            guard needles[0].count <= Int(spans[span + 1]) else { return false }
                            return memcmp(bytes.baseAddress! + Int(spans[span]), needles[0].baseAddress, needles[0].count) == 0
                        }
                        let moment = now.timeIntervalSinceReferenceDate
                        for at in entries.indices {
                            guard needles.allSatisfy({ has(at, Flat.path, $0) || has(at, Flat.title, $0) }) else { continue }
                            var score = Visit.score(weight: flat.weights[at * 3], since: moment - flat.weights[at * 3 + 1])
                            if !plain || begins(at, Flat.bare), entries[at].1.bare.hasPrefix(words[0]) { score *= 4 }
                            else if !plain || begins(at, Flat.title), entries[at].1.lowerTitle.hasPrefix(words[0]) { score *= 2 }
                            // Prefer the site's front page over a deep link of equal weight.
                            score /= flat.weights[at * 3 + 2]
                            scored.append((score, at))
                        }
                    }
                }
            }
            scored.sort { $0.score > $1.score }
            // One entry per page as it reads: www and trailing slashes don't make another.
            var seen = Set<String>()
            for (_, at) in scored {
                guard seen.insert(entries[at].1.bare + "\u{1}" + entries[at].0.title).inserted,
                      seen.insert(entries[at].1.bare).inserted else { continue }
                result.append(entries[at].0)
                if result.count == limit { break }
            }
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
        let entries = entries
        let flat = flattened(entries)
        entries.withUnsafeBufferPointer { entries in
            flat.bytes.withUnsafeBufferPointer { bytes in
                flat.spans.withUnsafeBufferPointer { spans in
                    start.withUnsafeBytes { start in
                        func starts(_ at: Int, _ field: Int) -> Bool {
                            let span = (at * Flat.fields + field) * 2
                            guard start.count <= Int(spans[span + 1]) else { return false }
                            return memcmp(bytes.baseAddress! + Int(spans[span]), start.baseAddress, start.count) == 0
                        }
                        for at in entries.indices {
                            // Bytes first: nearly every entry is turned away here.
                            guard starts(at, Flat.host) || starts(at, Flat.rawHost) || (deep && starts(at, Flat.bare)),
                                  let rawHost = entries[at].1.rawHost else { continue }
                            let host = entries[at].1.host
                            for candidate in deep ? [host, rawHost, entries[at].1.bare] : [host, rawHost]
                            where candidate.hasPrefix(prefix) && candidate.count > prefix.count {
                                let score = entries[at].0.score(now: now) + (candidate == host ? 0.5 : 0)
                                if best == nil || score > best!.1 { best = (candidate, score) }
                            }
                        }
                    }
                }
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
