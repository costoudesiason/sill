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
    private(set) var visits: [String: Visit] = [:] { didSet { changes += 1 } }
    /// Changes to `visits` since they were read.
    private var changes = 0
    private var knownHosts: Set<String>?
    /// The last answer to `recent`, kept until history changes: the empty
    /// palette asks each time it is shown or its field is cleared, and each
    /// answer is a sort of everything.
    private var latest: (limit: Int, visits: [Visit])?
    /// Five seconds: a page changing its title or address in a burst is one write, not many.
    private let saver = Saver<[Visit]>(Places.support.appendingPathComponent("history.json"), delay: 5)
    private static let cap = 6000

    private init() {
        // Read at launch, off the main thread (preload); waited for if not
        // done yet, which is never longer than reading it here would be.
        if let read = Self.early.read {
            read.wait()
            visits = Self.early.takeVisits() ?? Self.read()
            making = Self.early.making
            Self.early.making = nil
        } else {
            visits = Self.read()
        }
        Self.made = self
        if let making, making.work?.wait(timeout: .now()) == .success { finish(making) }
    }

    // MARK: - made in the background

    /// Reading six thousand entries took some 35 ms, and working out what
    /// searching needs of each (the shelf, below) 65 ms more, with another
    /// 20 for the sites known and the newest forty: paid on the main thread
    /// by the first page to record a visit and by the first letter typed in
    /// ⌘T. All of it is done here instead, in the background, as the app
    /// starts (main.swift).
    nonisolated static func preload() {
        let early = early
        let making = Making { early.visitsToPrepare() }
        let read = DispatchWorkItem(qos: .userInitiated) {
            early.put(visits: History.read())
            making.start()
        }
        early.read = read
        early.making = making
        DispatchQueue.global(qos: .userInitiated).async(execute: read)
    }

    nonisolated private static func read() -> [String: Visit] {
        let url = Places.support.appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Visit].self, from: data) else { return [:] }
        // Kept before checking-pages' titles were skipped: shown by address.
        let cleaned = list.map { visit -> Visit in
            var visit = visit
            if isPlaceholder(visit.title) { visit.title = "" }
            return visit
        }
        return Dictionary(cleaned.map { ($0.url, $0) }, uniquingKeysWith: { a, b in a.last > b.last ? a : b })
    }

    /// The one made, once it is: the background work hands it what it made.
    private static weak var made: History?

    /// What preload read, waiting for History's init, behind a lock.
    private final class Early: @unchecked Sendable {
        private let lock = NSLock()
        /// Both set once, on the main thread, before the app runs.
        var read: DispatchWorkItem?
        var making: Making?
        private var visits: [String: Visit]?
        private var forPreparing: [String: Visit]?
        func put(visits: [String: Visit]) { lock.withLock { self.visits = visits; forPreparing = visits } }
        func takeVisits() -> [String: Visit]? { lock.withLock { defer { visits = nil }; return visits } }
        func visitsToPrepare() -> [String: Visit]? { lock.withLock { defer { forPreparing = nil }; return forPreparing } }
    }
    nonisolated private static let early = Early()

    /// The shelf and the rest being made from a copy of the visits, off the
    /// main thread. What it made is read on the main thread once its work
    /// has finished (waited for, or told of), never while it runs.
    private final class Making: @unchecked Sendable {
        private(set) var work: DispatchWorkItem?
        private(set) var prepared: Prepared?
        private let source: @Sendable () -> [String: Visit]?
        private let at: Int

        /// `at`: how many changes there had been to the visits when copied.
        init(at: Int = 0, _ source: @escaping @Sendable () -> [String: Visit]?) {
            self.source = source
            self.at = at
        }

        /// Once, from the thread that made it, or the one reading at launch.
        func start() {
            let work = DispatchWorkItem(qos: .utility) { [weak self] in
                guard let self, let visits = self.source() else { return }
                self.prepared = Prepared(visits, at: self.at)
            }
            self.work = work
            work.notify(queue: .main) { [weak self] in
                MainActor.assumeIsolated { if let self { History.made?.finish(self) } }
            }
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    }
    private var making: Making?

    /// Everything searching and the palette work out from history, made
    /// from the visits as they were when copied.
    private struct Prepared: @unchecked Sendable {
        let visits: [String: Visit]
        let at: Int
        let shelf: [(Visit, Reading)]
        let places: [String: Int]
        let readings: [String: Reading]
        let flat: Flat
        let knownHosts: Set<String>
        let recent: [Visit]

        init(_ visits: [String: Visit], at: Int) {
            self.visits = visits
            self.at = at
            let shelf = visits.values.map { ($0, History.makeReading($0)) }
            self.shelf = shelf
            places = Dictionary(uniqueKeysWithValues: shelf.enumerated().map { ($1.0.url, $0) })
            readings = Dictionary(uniqueKeysWithValues: shelf.map { ($0.0.url, $0.1) })
            var flat = Flat()
            flat.spans.reserveCapacity(shelf.count * Flat.fields * 2)
            for (visit, read) in shelf { flat.add(visit, read) }
            flat.live = flat.bytes.count
            self.flat = flat
            knownHosts = Set(visits.values.compactMap { $0.address.map { Domains.bare($0.host()) } })
            recent = Array(visits.values.sorted { $0.last > $1.last }.prefix(History.recentLimit))
        }
    }

    /// The palette's list of recent sites asks for this many.
    nonisolated static let recentLimit = 40

    /// Made again in the background after a change to many entries at once
    /// (trimmed, merged from Safari, one removed): the next letter typed
    /// would otherwise make it all again on the main thread.
    private func makeAgain() {
        let making = Making(at: changes) { [visits] in visits }
        self.making = making
        making.start()
    }

    /// Takes what was made in the background, unless something newer is on
    /// its way or the shelf has been made here already. Changes made since
    /// the copy are put on top of it; if any entry it holds has gone since,
    /// it is let go and made again when wanted.
    private func finish(_ done: Making) {
        guard done === making else { return }
        making = nil
        guard let prepared = done.prepared, shelf == nil else { return }
        // Nothing changed since the copy (the usual case): no entry to compare.
        let same = changes == prepared.at
        guard same || !prepared.visits.keys.contains(where: { visits[$0] == nil }) else { return }
        readings = prepared.readings
        places = prepared.places
        shelf = prepared.shelf
        flat = prepared.flat
        if knownHosts == nil { knownHosts = prepared.knownHosts }
        if latest == nil { latest = (Self.recentLimit, prepared.recent) }
        if !same { for (key, visit) in visits where prepared.visits[key] != visit { noted(visit) } }
    }

    /// Asked for before the background has finished (a letter typed in the
    /// first moment after launch): waiting for it beats making it twice.
    private func awaitPrepared() {
        guard shelf == nil, let making, let work = making.work else { return }
        work.wait()
        finish(making)
    }

    static func key(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var text = components?.string ?? url.absoluteString
        if text.hasSuffix("/") && components?.path == "/" { text.removeLast() }
        return text
    }

    /// What a site shows while it checks you're a person (Cloudflare and
    /// the like): never a page's title, so never kept as one.
    nonisolated static func isPlaceholder(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("just a moment") || t.hasPrefix("attention required") || t.hasPrefix("please wait")
            || t.hasPrefix("checking your browser") || t == "ddos-guard" || t.hasPrefix("one moment, please")
            || t == "security check" || t.hasPrefix("verifying you are human")
    }

    func record(_ url: URL, title: String?, typed: Bool = false) {
        guard let key = Self.key(url) else { return }
        var visit = visits[key] ?? Visit(url: key, title: "", count: 0, last: Date())
        visit.count += 1
        visit.last = Date()
        if typed { visit.typed += 1 }
        if let title, !title.isEmpty, !Self.isPlaceholder(title) { visit.title = title }
        visits[key] = visit
        noted(visit)
        trim()
        persist()
    }

    func retitle(_ url: URL, _ title: String) {
        guard !title.isEmpty, !Self.isPlaceholder(title), let key = Self.key(url), var visit = visits[key], visit.title != title else { return }
        visit.title = title
        visits[key] = visit
        noted(visit)
        persist()
    }

    /// Forgets everything worked out from the entries: for a change to many of them at once.
    private func changed() {
        knownHosts = nil; shelf = nil; flat = nil; latest = nil
        makeAgain()
    }

    /// One entry is new, or has a later visit or another title: what is kept
    /// about all of them is brought up to date for that one, where making it
    /// again is a pass over the whole of history after every page.
    private func noted(_ visit: Visit) {
        if knownHosts != nil, let host = visit.address?.host() { knownHosts?.insert(Domains.bare(host)) }
        if let limit = latest?.limit {
            // The list is newest first. A retitle keeps an entry where it is;
            // a visit now goes to the front. Anything else that could belong
            // part-way down (the clock went back, an entry dated ahead) has
            // the list made again.
            let at = latest?.visits.firstIndex(where: { $0.url == visit.url })
            if let at, latest?.visits[at].last == visit.last {
                latest?.visits[at] = visit
            } else if let newest = latest?.visits.first, visit.last < newest.last {
                let full = (latest?.visits.count ?? 0) >= limit
                let oldest = latest?.visits.last?.last ?? visit.last
                if at != nil || !full || visit.last > oldest { latest = nil }
            } else {
                if let at { latest?.visits.remove(at: at) }
                latest?.visits.insert(visit, at: 0)
                if (latest?.visits.count ?? 0) > limit { latest?.visits.removeLast() }
            }
        }
        guard shelf != nil else { return }
        let read = reading(visit)
        if let at = places[visit.url] {
            let same = shelf?[at].0.title == visit.title
            shelf?[at] = (visit, read)
            guard flat != nil else { return }
            flat?.weights[at * 3] = Double(visit.count) + Double(visit.typed) * 2
            flat?.weights[at * 3 + 1] = visit.last.timeIntervalSinceReferenceDate
            if !same {
                // The title's new bytes go on the end; the old ones stay behind, unread.
                let end = Int32(flat?.bytes.count ?? 0)
                flat?.spans[(at * Flat.fields + Flat.title) * 2] = end
                flat?.spans[(at * Flat.fields + Flat.title) * 2 + 1] = Int32(read.titleBytes.count)
                flat?.bytes.append(contentsOf: read.titleBytes)
                // A page that keeps renaming itself leaves a title behind each
                // time: past a point the whole is made again without them.
                if let flat, flat.bytes.count > flat.live * 2 + 65_536 { self.flat = nil }
            }
        } else {
            places[visit.url] = shelf?.count ?? 0
            shelf?.append((visit, read))
            flat?.add(visit, read)
        }
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
        changed()
        trim()
        persist()
    }

    /// Forgets one entry; what it was comes back, for an Undo.
    @discardableResult
    func remove(_ key: String) -> Visit? {
        guard let gone = visits.removeValue(forKey: key) else { return nil }
        changed()
        persist()
        return gone
    }

    /// Forgets every entry that matches (since a time, or on one site), in one write.
    @discardableResult
    func remove(where matches: (Visit) -> Bool) -> [Visit] {
        let gone = visits.values.filter(matches)
        guard !gone.isEmpty else { return [] }
        for visit in gone { visits[visit.url] = nil }
        changed()
        persist()
        return gone
    }

    /// Puts back what was just removed (Undo).
    func restore(_ list: [Visit]) {
        guard !list.isEmpty else { return }
        for visit in list { visits[visit.url] = visit }
        changed()
        persist()
    }

    func markTyped(_ url: URL) {
        guard let key = Self.key(url), var visit = visits[key] else { return }
        visit.typed += 1
        visits[key] = visit
        noted(visit)
        // Not a write of its own: it goes with the next one, or at quit.
        edits += 1
    }

    @discardableResult
    func clear() -> [Visit] {
        let gone = Array(visits.values)
        visits = [:]
        changed()
        persist()
        return gone
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
    /// Where each address stands on the shelf.
    private var places: [String: Int] = [:]

    private var entries: [(Visit, Reading)] {
        awaitPrepared()
        if let shelf { return shelf }
        let made = visits.values.map { ($0, reading($0)) }
        places = Dictionary(uniqueKeysWithValues: made.enumerated().map { ($1.0.url, $0) })
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
        /// How many of the bytes were there when it was made, none of them left behind.
        var live = 0

        mutating func add(_ visit: Visit, _ read: Reading) {
            weights.append(Double(visit.count) + Double(visit.typed) * 2)
            weights.append(visit.last.timeIntervalSinceReferenceDate)
            weights.append(read.depth)
            for field in [read.pathBytes, read.titleBytes, read.hostBytes, read.rawHostBytes, read.bareBytes] {
                spans.append(Int32(bytes.count))
                spans.append(Int32(field.count))
                bytes.append(contentsOf: field)
            }
        }
    }
    private var flat: Flat?

    private func flattened(_ entries: [(Visit, Reading)]) -> Flat {
        if let flat { return flat }
        var made = Flat()
        made.spans.reserveCapacity(entries.count * Flat.fields * 2)
        for (visit, read) in entries { made.add(visit, read) }
        made.live = made.bytes.count
        flat = made
        return made
    }

    nonisolated private static func bytes(_ text: String) -> ContiguousArray<UInt8> {
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
        let made = Self.makeReading(visit)
        readings[visit.url] = made
        return made
    }

    /// On any thread: preload makes them in the background.
    nonisolated private static func makeReading(_ visit: Visit) -> Reading {
        let url = visit.address
        let bare = Address.display(url).lowercased()
        let rawHost = url?.host()?.lowercased()
        let path = url.map { (($0.host() ?? "") + $0.path).lowercased() } ?? visit.url.lowercased()
        let host = Domains.bare(rawHost)
        let lowerTitle = visit.title.lowercased()
        return Reading(path: path,
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
                            let start = bytes.baseAddress! + Int(spans[span])
                            guard let hit = memmem(start, count, needle.baseAddress, needle.count) else { return false }
                            // Bytes can match inside a character ("i" in "i̇", a flag's
                            // first half): only a hit with plain letters either side is
                            // taken as it is, the rest are asked of the text itself.
                            let from = UnsafeRawPointer(start).distance(to: UnsafeRawPointer(hit)), to = from + needle.count
                            if needle[0] < 0x80 || from == 0 || start[from - 1] < 0x80, to == count || start[to] < 0x80 { return true }
                            let word = words[needles.firstIndex { $0.baseAddress == needle.baseAddress } ?? 0]
                            return field == Flat.path ? entries[at].1.path.contains(word) : entries[at].1.lowerTitle.contains(word)
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

    /// Searches made before, read from the results pages in history: each
    /// query once (in its most visited spelling), with its visits summed.
    /// Made again only after history changes, and then only the few entries
    /// with a query in their address are read.
    private struct PastSearch {
        let query: String
        let lower: String
        let weight: Double
        let last: Date
    }
    private var pastSearches: (at: Int, list: [PastSearch])?

    private func searchList() -> [PastSearch] {
        if let pastSearches, pastSearches.at == changes { return pastSearches.list }
        var byQuery: [String: (query: String, best: Int, weight: Double, last: Date)] = [:]
        for visit in visits.values where visit.url.contains("q=") {
            guard let query = SearchEngine.google.query(in: visit.address) else { continue }
            let lower = query.lowercased()
            let weight = Double(visit.count) + Double(visit.typed) * 2
            if var known = byQuery[lower] {
                if visit.count > known.best { known.query = query; known.best = visit.count }
                known.weight += weight
                known.last = max(known.last, visit.last)
                byQuery[lower] = known
            } else {
                byQuery[lower] = (query, visit.count, weight, visit.last)
            }
        }
        let list = byQuery.map { PastSearch(query: $0.value.query, lower: $0.key, weight: $0.value.weight, last: $0.value.last) }
        pastSearches = (changes, list)
        return list
    }

    /// Searches made before that begin with what's typed (or whose words
    /// do), best first, not counting the one typed exactly.
    func searches(matching text: String, limit: Int) -> [String] {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty else { return [] }
        let words = lower.split(separator: " ").map { String($0) }
        let now = Date()
        var hits: [(query: String, score: Double)] = []
        for search in searchList() where search.lower != lower {
            let begins = search.lower.hasPrefix(lower)
            // Its words matched further in only once there's enough typed to mean
            // something: "y" isn't looking for "do you need".
            guard begins || (lower.count >= 4 && words.allSatisfy({ search.lower.hasPrefix($0) || search.lower.contains(" " + $0) }))
            else { continue }
            let score = Visit.score(weight: search.weight, since: now.timeIntervalSince(search.last))
            hits.append((search.query, begins ? score * 2 : score))
        }
        return hits.sorted { $0.score > $1.score }.prefix(limit).map(\.query)
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
                            // Never into a page's query ("youtube.com/w" to one video
                            // of many): those are in the list below the field.
                            for candidate in deep ? [host, rawHost, entries[at].1.bare] : [host, rawHost]
                            where candidate.hasPrefix(prefix) && candidate.count > prefix.count && !candidate.contains("?") {
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
        changed()
    }

    /// How many changes there have been, and how many of them are on disk.
    private var edits = 0
    private var saved = 0

    private func persist() {
        edits += 1
        var held = 0
        saver.save({ [weak self] in
            guard let self else { return [] }
            held = self.edits
            return Array(self.visits.values)
        }, written: { [weak self] in
            guard let self else { return }
            self.saved = max(self.saved, held)
        })
    }

    /// At quit. Nothing to write when the file already holds every change:
    /// encoding all of history is the larger part of quitting.
    func flush() {
        guard saved != edits else { return }
        saver.flush(Array(visits.values))
        saved = edits
    }
}
