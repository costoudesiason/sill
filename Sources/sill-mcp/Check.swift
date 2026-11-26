import Foundation

/// Everything the model was shown from pages, kept as it came back: the evidence for its answer.
/// Filled from the answers of the reading tools at no cost (no extra calls, nothing reloaded).
/// Subagents of one client share the process, so they share it too. Old reads age out.
enum Evidence {
    struct Read { let url: String; let at: Date; let stamp: String; let lines: [String] }
    private static let lock = NSLock()
    private static var reads: [Read] = []
    static let keep: TimeInterval = 3 * 3600
    static let readingTools: Set<String> = ["page_read", "read_url", "tabs_open", "page_do", "page_navigate", "page_text",
                                            "page_snapshot", "web_search", "page_goal", "page_find", "files"]

    static func add(tool: String, text: String) {
        guard readingTools.contains(tool), !text.isEmpty else { return }
        let url = text.range(of: #"https?://[^\s)\]"'>]+"#, options: .regularExpression).map { String(text[$0]) } ?? tool
        let lines = split(text)
        guard !lines.isEmpty else { return }
        let read = Read(url: url, at: Date(), stamp: readStamp(), lines: lines)
        lock.withLock {
            reads.append(read)
            let cutoff = Date().addingTimeInterval(-keep)
            reads.removeAll { $0.at < cutoff }
            if reads.count > 400 { reads.removeFirst(reads.count - 400) }
        }
    }

    static func all() -> [Read] { lock.withLock { reads } }

    /// Lines of a reasonable length: long ones cut at sentence ends.
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.count < 2 || line.hasPrefix("(read at ") || line.hasPrefix("[Page text:") { continue }
            if line.count <= 300 { out.append(line); continue }
            var piece = ""
            for s in line.components(separatedBy: ". ") {
                if piece.count + s.count > 280, !piece.isEmpty { out.append(piece); piece = "" }
                piece += (piece.isEmpty ? "" : ". ") + s
            }
            if !piece.isEmpty { out.append(String(piece.prefix(400))) }
        }
        return out
    }
}

/// The check before a final answer: the draft against what was actually read. Mechanical and
/// instant: for each condition, the lines read that speak to it (or none); each figure in the
/// draft, and whether any page showed it; and for a "lowest / highest" claim, the range the page showed.
enum AnswerCheck {
    static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "has", "have",
        "its", "into", "than", "then", "them", "they", "their", "there", "which", "what", "when", "where", "who", "whose",
        "must", "should", "only", "each", "every", "any", "all", "not", "but", "also", "about", "over", "under", "least",
        "most", "more", "less", "one", "two", "per", "via", "find", "show", "give", "list", "get", "use", "using", "user",
        "task", "page", "site", "result", "results", "item", "items", "include", "includes", "including", "within",
        "between", "less", "your", "you", "our", "can", "will", "would", "could", "need", "needs", "make", "sure"]

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// Same word, loosely: "modules" ~ "module", "agile" ~ "agility" (a common start of 5).
    static func matches(_ word: String, in lineWords: Set<String>) -> Bool {
        if lineWords.contains(word) { return true }
        guard word.count >= 5, !word.allSatisfy(\.isNumber) else { return false }
        let head = word.prefix(5)
        return lineWords.contains { $0.count >= 5 && $0.hasPrefix(head) }
    }

    struct Figure { let shown: String; let value: Double; let currency: String? }

    /// Money and numbers in a text: "$1,011.50", "AED 1,011", "€20", "4.8", "35%", "2,482".
    static func figures(_ s: String) -> [Figure] {
        let pattern = #"(US\$|C\$|A\$|\$|€|£|¥|₹|AED|USD|EUR|GBP|CAD|JPY)?\s?(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)\s?(%|USD|EUR|GBP|AED)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        var out: [Figure] = []
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let num = ns.substring(with: m.range(at: 2))
            let before = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
            let after = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)) : nil
            guard let value = Double(num.replacingOccurrences(of: ",", with: "")) else { continue }
            // Plain small integers ("2 adults", "step 3") and years say too little to check.
            let plain = before == nil && after == nil
            if plain && !num.contains(".") && !num.contains(",") && (value < 10 || (1900...2100).contains(value)) { continue }
            var currency = before ?? (after == "%" ? nil : after)
            if currency == "USD" || currency == "US$" { currency = "$" }
            if currency == "EUR" { currency = "€" }
            if currency == "GBP" { currency = "£" }
            out.append(Figure(shown: ns.substring(with: m.range).trimmingCharacters(in: .whitespaces), value: value,
                              currency: after == "%" ? "%" : currency))
        }
        return out
    }

    static let extremes = #"\b(lowest|cheapest|least expensive|highest|most expensive|priciest|largest|biggest|smallest|most|fewest|top|best[- ]rated|highest[- ]rated)\b"#

    static func run(answer: String, needs: [String]) -> String {
        let reads = Evidence.all()
        if reads.isEmpty { return "Nothing read from a page yet in this session, so there is nothing to check the answer against: read the pages first." }
        let indexed: [(read: Evidence.Read, line: String, words: Set<String>)] =
            reads.flatMap { r in r.lines.map { (r, $0, Set(words($0))) } }
        var out: [String] = []

        // 1. Each condition: the lines that speak to it.
        if !needs.isEmpty {
            out.append("Conditions, with the lines you read that speak to each (judge whether they meet it):")
            for (i, need) in needs.enumerated() {
                let keys = Array(Set(words(need)))
                guard !keys.isEmpty else { out.append("\(i + 1). \(need)\n   (no words to look for: check it yourself)"); continue }
                // Rare words count for more ("agile" over "course"); every word of the condition gets
                // its best line, so the line that names the thing itself is never crowded out.
                let n = Double(max(indexed.count, 1))
                var weight: [String: Double] = [:]
                for k in keys {
                    let df = Double(indexed.filter { matches(k, in: $0.words) }.count)
                    weight[k] = df == 0 ? 0 : log(1 + n / df)
                }
                let total = keys.reduce(0) { $0 + (weight[$1] ?? 0) }
                var ranked: [(score: Double, line: String, url: String, hit: Set<String>)] = []
                var seen = Set<String>()
                for entry in indexed.reversed() {   // newest first, so a later read of the same line wins
                    let hit = Set(keys.filter { matches($0, in: entry.words) })
                    guard !hit.isEmpty, seen.insert(entry.line).inserted else { continue }
                    ranked.append((hit.reduce(0) { $0 + (weight[$1] ?? 0) }, entry.line, entry.read.url, hit))
                }
                ranked.sort { $0.score > $1.score }
                var picked = Array(ranked.prefix(2).filter { total == 0 || $0.score >= total * 0.3 })
                for k in keys.sorted(by: { (weight[$0] ?? 0) > (weight[$1] ?? 0) }) where picked.count < 4 && (weight[k] ?? 0) > 0 {
                    if picked.contains(where: { $0.hit.contains(k) }) { continue }
                    if let best = ranked.first(where: { $0.hit.contains(k) }) { picked.append(best) }
                }
                let scored = picked.map { (0, $0.line, $0.url) }
                if scored.isEmpty {
                    out.append("\(i + 1). \(need)\n   Nothing you read mentions this. Check it on the page (or say it's unverified) before claiming it.")
                } else {
                    out.append("\(i + 1). \(need)\n" + scored.prefix(3).map { "   · \(String($0.1.prefix(220)))  [\($0.2)]" }.joined(separator: "\n"))
                }
            }
        }

        // 2. Each figure in the draft: shown on a page, or not.
        let claimed = figures(answer)
        var missing: [String] = []
        var seenFig = Set<String>()
        let allFigures: [(Figure, Evidence.Read, String)] = indexed.flatMap { e in figures(e.line).map { ($0, e.read, e.line) } }
        for f in claimed where seenFig.insert(f.shown).inserted {
            let found = allFigures.contains { abs($0.0.value - f.value) < 0.005 && (f.currency == nil || $0.0.currency == nil || $0.0.currency == f.currency) }
            if !found { missing.append(f.shown) }
        }
        if !claimed.isEmpty {
            out.append(missing.isEmpty ? "Figures: every figure in your answer appears on a page you read."
                       : "Figures not on any page you read: \(missing.joined(separator: ", ")). If you worked them out (a conversion, a sum), say so; if not, read them again.")
        }

        // 3. A "lowest / highest" claim: the range of amounts the same pages showed.
        if answer.range(of: extremes, options: [.regularExpression, .caseInsensitive]) != nil {
            for f in claimed where f.currency != nil && f.currency != "%" {
                let pages = Set(allFigures.filter { abs($0.0.value - f.value) < 0.005 && $0.0.currency == f.currency }.map { $0.1.url })
                guard !pages.isEmpty else { continue }
                let same = allFigures.filter { pages.contains($0.1.url) && $0.0.currency == f.currency }.map { $0.0.value }
                guard let lo = same.min(), let hi = same.max(), lo < hi else { continue }
                let cur = f.currency ?? ""
                out.append("On the page(s) showing \(f.shown), amounts in \(cur) ran from \(cur)\(fmt(lo)) to \(cur)\(fmt(hi)): if you called \(f.shown) the lowest or highest, make sure nothing on the page beats it (fees, per-night vs total, a sort or tab you didn't open).")
            }
        }
        out.append("Read \(reads.count) time(s) from \(Set(reads.map(\.url)).count) source(s) in the last \(Int(Evidence.keep / 3600)) h. Fix what's off, then answer.")
        return out.joined(separator: "\n")
    }

    static func fmt(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}

let checkTool = Tool(name: "answer_check",
    description: "Before your final answer: your draft and the task's conditions (each one spelled out, including what the user implied), checked in milliseconds against everything you read from pages. Says which lines back each condition (or that nothing you read does), which figures in your draft no page showed, and for a lowest/highest claim the range the page showed.",
    properties: ["answer": ["type": "string", "description": "Your draft final answer."],
                 "needs": ["type": "array", "items": ["type": "string"], "description": "The task's conditions, one per item: what the result must be or have."]],
    required: ["answer"], readOnly: true, openWorld: false) { _, args in
    [.text(AnswerCheck.run(answer: args["answer"] as? String ?? "", needs: (args["needs"] as? [String]) ?? []))]
}
