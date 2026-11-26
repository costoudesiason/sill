import Foundation

/// The task's conditions, given once (needs=[…] on the first call) and kept for the task: every
/// page read then points at what on that page speaks to each one, with refs to act on, and counts
/// how many items pass a price or rating limit. The agent goes straight to the control or line
/// that matters instead of hunting for it, and sees early when a page can't meet a condition.
enum Needs {
    private static let lock = NSLock()
    private static var list: [String] = []
    private static var shown: [String: String] = [:]   // tab → the last block shown there

    static func set(_ needs: [String]) {
        // needs=[] clears them: a new task.
        let clean = needs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(8).map { String($0.prefix(160)) }
        lock.withLock { if Array(clean) != list { list = Array(clean); shown = [:] } }
    }
    static func current() -> [String] { lock.withLock { list } }

    struct Limit { let low: Double?; let high: Double?; let money: Bool }

    /// "under $250", "at least 4 stars", "between $100 and $300", "rated 4.5 or higher".
    static func limit(_ need: String) -> Limit? {
        let n = need.lowercased()
        let money = n.range(of: #"[$€£¥₹]|\b(usd|eur|gbp|dollars?|euros?|pounds?|price|priced|cost|costs|fare|budget|cheaper)\b"#, options: .regularExpression) != nil
        let rating = n.range(of: #"\b(stars?|rating|rated|reviews? score)\b|★"#, options: .regularExpression) != nil
        guard money || rating else { return nil }
        let num = #"(?:us\$|\$|€|£|¥|₹)?\s?(\d[\d,]*(?:\.\d+)?)"#
        func value(_ pattern: String) -> [Double] {
            guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) else { return [] }
            return (1..<m.numberOfRanges).compactMap { i in Range(m.range(at: i), in: n).flatMap { Double(n[$0].replacingOccurrences(of: ",", with: "")) } }
        }
        let between = value(#"between\s+"# + num + #"\s+(?:and|to|-|–)\s+"# + num)
        if between.count == 2 { return Limit(low: min(between[0], between[1]), high: max(between[0], between[1]), money: money) }
        let range = value(num + #"\s*(?:-|–|to)\s*"# + num)
        if range.count == 2, range[0] < range[1] { return Limit(low: range[0], high: range[1], money: money) }
        let high = value(#"(?:under|below|less than|cheaper than|at most|no more than|max(?:imum)?|up to|within|<=?|≤)\s*"# + num).first
            ?? value(num + #"\s*(?:or less|or under|or below|max|and under|and below)"#).first
        let low = value(#"(?:over|above|more than|at least|min(?:imum)?|>=?|≥)\s*"# + num).first
            ?? value(num + #"\s*(?:\+|or more|or higher|or above|and up|and above|stars? (?:and|or) (?:up|above|higher))"#).first
        guard high != nil || low != nil else { return nil }
        return Limit(low: low, high: high, money: money)
    }

    /// An item's rating on its line: "4.8 out of 5", "4.5 stars", "★ 4.7", "rated 4.2", "4.8 (2,482)".
    static func rating(_ line: String) -> Double? {
        let pattern = #"(\d(?:\.\d)?)\s*(?:out of 5|/\s*5\b|stars?\b|★)|★\s*(\d(?:\.\d)?)|rated\s+(\d(?:\.\d)?)|\b([1-5]\.\d)\s*\(\d[\d,]*\)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        for i in 1..<m.numberOfRanges { if let r = Range(m.range(at: i), in: line), let v = Double(line[r]), v <= 5 { return v } }
        return nil
    }


    /// Each amount in a line with the words before it (back to the previous amount): "TAP · 1 stop · $235".
    static func prices(in line: String) -> [(String, Double)] {
        let pattern = #"(US\$|C\$|A\$|\$|€|£|¥|₹)\s?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)"#
        return pieces(line, pattern) { Double($0.replacingOccurrences(of: ",", with: "")) }
    }
    static func ratings(in line: String) -> [(String, Double)] {
        let pattern = #"(?:★\s*)?\b([1-5](?:\.\d)?)\s*(?:out of 5|/\s*5\b|stars?\b|★|\(\d[\d,]*\))"#
        return pieces(line, pattern) { Double($0) }
    }
    private static func pieces(_ line: String, _ pattern: String, _ value: (String) -> Double?) -> [(String, Double)] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = line as NSString
        var out: [(String, Double)] = []
        var from = 0
        for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            let numRange = m.range(at: m.numberOfRanges - 1)
            guard numRange.location != NSNotFound, let v = value(ns.substring(with: numRange)) else { continue }
            let end = m.range.location + m.range.length
            let start = max(from, end - 60)
            var piece = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            if start > from, let space = piece.firstIndex(of: " ") { piece = String(piece[piece.index(after: space)...]) }
            while piece.hasPrefix("·") || piece.hasPrefix("•") || piece.hasPrefix("-") { piece = String(piece.dropFirst()).trimmingCharacters(in: .whitespaces) }
            out.append((piece, v))
            from = end
        }
        return out
    }

    /// The block for a page, or nil when there are no conditions or it says what it said last time here.
    static func block(tab: String, lines: [String]) -> String? {
        let needs = current()
        guard !needs.isEmpty, lines.count > 2 else { return nil }
        let body = lines.dropFirst(2).filter { !$0.hasPrefix("(read at ") && !$0.hasPrefix("Site links: ") && !$0.hasPrefix("Footer links: ") }
        let indexed = body.map { ($0, Set(AnswerCheck.words($0))) }
        var out: [String] = []
        for need in needs {
            var said: [String] = []
            if let lim = limit(need) {
                // Every price (or rating) in the page's text, with the words just before it as what it's
                // for, and how many pass the limit. Controls (a "Under $250" filter) aren't items.
                var items: [(String, Double)] = []
                for line in body where !line.hasPrefix("State: ") && !line.hasPrefix("List: ") && !line.hasPrefix("[") && !line.hasPrefix("#") {
                    items += lim.money ? prices(in: line) : ratings(in: line)
                }
                if items.count >= 2 {
                    let pass = items.filter { item in (lim.low.map { item.1 >= $0 } ?? true) && (lim.high.map { item.1 <= $0 } ?? true) }
                    let what = lim.money ? "prices" : "ratings"
                    said.append("\(pass.count) of \(items.count) \(what) here meet it" + (pass.isEmpty ? "" : ": " + pass.prefix(4).map { "“" + $0.0 + "”" }.joined(separator: "; ")))
                }
            }
            // A price or rating limit is answered by the count above: its own words ("price", "under") match too much.
            let limitWords: Set<String> = ["price", "priced", "prices", "cost", "costs", "fare", "fares", "budget", "cheaper", "cheap",
                "usd", "eur", "gbp", "dollars", "dollar", "euros", "pounds", "stars", "star", "rating", "rated", "higher", "lower",
                "above", "below", "maximum", "minimum", "max", "min"]
            let keys = Array(Set(AnswerCheck.words(need))).filter { Double($0) == nil && !(limit(need) != nil && limitWords.contains($0)) }
            if !keys.isEmpty {
                let n = Double(max(indexed.count, 1))
                var weight: [String: Double] = [:]
                for k in keys {
                    let df = Double(indexed.filter { AnswerCheck.matches(k, in: $0.1) }.count)
                    weight[k] = df == 0 ? 0 : log(1 + n / df)
                }
                let total = keys.reduce(0) { $0 + (weight[$1] ?? 0) }
                let ranked = indexed.compactMap { (line, words) -> (Double, String)? in
                    let score = keys.filter { AnswerCheck.matches($0, in: words) }.reduce(0) { $0 + (weight[$1] ?? 0) }
                    return score > 0 ? (score + (line.hasPrefix("[") ? 0.01 : 0), line) : nil
                }.sorted { $0.0 > $1.0 }
                // The lines that carry most of the condition's rare words: controls (with refs) first among equals.
                var used: [String] = []
                for (score, line) in ranked.prefix(3) where total > 0 && score >= total * 0.34 && said.count < 3 {
                    said.append(clip(line, 150)); used.append(line)
                }
                // Every word of the condition gets its best line (rarest first), so "agile" isn't crowded out
                // by "course" and "module".
                for k in keys.filter({ (weight[$0] ?? 0) > 0 }).sorted(by: { (weight[$0] ?? 0) > (weight[$1] ?? 0) }) where said.count < 4 {
                    if used.contains(where: { AnswerCheck.matches(k, in: Set(AnswerCheck.words($0))) }) { continue }
                    if let best = ranked.first(where: { AnswerCheck.matches(k, in: Set(AnswerCheck.words($0.1))) }) {
                        said.append(clip(best.1, 150)); used.append(best.1)
                    }
                }
            }
            out.append("· “\(clip(need, 70))” → " + (said.isEmpty ? "nothing on this page speaks to it" : said.joined(separator: "  |  ")))
        }
        let text = "For your conditions:\n" + out.joined(separator: "\n")
        return lock.withLock {
            if shown[tab] == text { return nil }
            shown[tab] = text
            return text
        }
    }
}

let needsProperty: [String: Any] = ["type": "array", "items": ["type": "string"],
    "description": "The task's conditions, given once and kept for the task (each one spelled out: what the user said and what they plainly meant). Every page then points at what on it meets each, and answer_check uses them."]
