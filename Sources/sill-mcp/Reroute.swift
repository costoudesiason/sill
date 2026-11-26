import Foundation

/// The way around a dead end, found before the agent has to ask: like a map recalculating.
/// - Blocked (the site refuses this browser, its certificate isn't valid, it can't be reached, it's failing):
///   the same thing from other sources, by a web search for what the task wants, the blocked site left out.
/// - Not found (404, a removed page): where it lives now on the same site, by a search of that site.
/// - No results: what's narrowing it (the filters on, the words typed), to loosen one at a time.
/// Searches only at a dead end, once per address, so a page that works costs nothing.
enum Reroute {
    private static let lock = NSLock()
    private static var done: Set<String> = []

    enum Kind { case blocked(String), notFound(String), empty(String) }

    static let notFoundPattern = #"(^|\s)404(\s*$|\s*[-–:|·]?\s*(error|not found|page))|\b(error|http|status)\s*(code)?:?\s*404\b|\b(page not found|not found|doesn[’']t exist|does not exist|no longer (available|exists)|has been (removed|deleted)|can[’']t find (that|this|the) page|couldn[’']t find (that|this|the) page|page (is )?unavailable)\b"#
    static let failingPattern = #"\b(error|http|status)\s*(code)?:?\s*5\d\d\b|(^|\s)5\d\d\s*[-–:|·]?\s*(error|internal)|\b(internal server error|service (temporarily )?unavailable|bad gateway|gateway time-?out)\b"#
    static let emptyPattern = #"\b(no results|0 results|no matches|no matching|nothing (matched|found)|we couldn[’']t find any|did not match any|didn[’']t match any|returned no results|no (items|products|listings|properties|jobs|flights|hotels|courses|stays|homes|results) (were )?(found|match|available))\b"#

    static func kind(_ lines: [String]) -> Kind? {
        guard lines.count >= 2 else { return nil }
        let title = lines[0].components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        let body = Array(lines.dropFirst(2).prefix(60))
        if title == "Can’t open this page" || title == "Can't open this page" {
            // The error itself ("The site’s certificate isn’t valid…"), not Sill's own notes about the page.
            let text = body.filter { !$0.hasPrefix("[") && !$0.hasPrefix("#") && !$0.hasPrefix("(") && !$0.hasPrefix("State: ") && $0.count > 12 }
            let why = text.first { $0.range(of: #"certificate|can[’']t be found|offline|refused|too long|closed|couldn[’']t|can[’']t open|denied|blocked"#, options: [.regularExpression, .caseInsensitive]) != nil }
                ?? text.first ?? "it couldn't be opened"
            return .blocked(why)
        }
        if let wall = body.first(where: { $0.hasPrefix("⚠ The site is refusing this browser") }) { return .blocked(String(wall.dropFirst(2).prefix(90))) }
        let headings = body.filter { $0.hasPrefix("#") }.prefix(2).joined(separator: " ")
        // The page's first words too: error pages often say it in a line, not a heading ("Error code: 404").
        let opening = body.filter { !$0.hasPrefix("[") && !$0.hasPrefix("State: ") && !$0.hasPrefix("List: ") }.prefix(4).joined(separator: " ")
        let top = title + " " + headings
        let coded = #"\b(error|http|status)\s*(code)?:?\s*"#
        let said = clip(title.isEmpty ? headings : title, 60)
        if top.range(of: failingPattern, options: [.regularExpression, .caseInsensitive]) != nil
            || opening.range(of: coded + #"5\d\d\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .blocked("the site is failing (“\(said)”)") }
        if top.range(of: notFoundPattern, options: [.regularExpression, .caseInsensitive]) != nil
            || opening.range(of: coded + #"404\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .notFound(said) }
        if !body.contains(where: { $0.hasPrefix("List: ") }),
           let line = body.first(where: { !$0.hasPrefix("[") && $0.range(of: emptyPattern, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return .empty(clip(line, 100))
        }
        return nil
    }

    /// What the task wants, as search words: its conditions if given, else the page's own words.
    static func words(_ lines: [String], url: URL?) -> String {
        let needs = Needs.current()
        if !needs.isEmpty {
            // The words that name the thing, not the limits ("at least", "rated", "or higher", amounts).
            let filler: Set<String> = ["least", "rated", "rating", "higher", "lower", "above", "below", "between", "price", "priced",
                                       "cost", "stars", "star", "cheaper", "budget", "within", "maximum", "minimum", "only", "must", "should"]
            var seenWord = Set<String>()
            return needs.flatMap { AnswerCheck.words($0) }.filter { !filler.contains($0) && Double($0) == nil && seenWord.insert($0).inserted }
                .prefix(9).joined(separator: " ")
        }
        let title = lines[0].components(separatedBy: " · ").dropFirst().joined(separator: " ")
        if !title.isEmpty, title.range(of: "Can.t open this page|" + notFoundPattern + "|" + failingPattern, options: [.regularExpression, .caseInsensitive]) == nil {
            return clip(title, 80)
        }
        // The address's own words: path parts and query values that read as words, not ids.
        var parts: [String] = []
        if let url {
            parts += url.path.components(separatedBy: CharacterSet(charactersIn: "/-_.+")).filter { $0.count >= 3 && $0.rangeOfCharacter(from: .letters) != nil && $0.filter(\.isNumber).count * 2 < $0.count }
            if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                parts += q.compactMap(\.value).filter { $0.count >= 3 && $0.count <= 60 && $0.contains(where: \.isLetter) && !$0.contains("=") }
            }
        }
        return parts.prefix(8).joined(separator: " ").replacingOccurrences(of: "+", with: " ")
    }

    /// Search results as (title, url, snippet) blocks, those on `host` left out or kept only.
    static func results(_ text: String, host: String, sameSite: Bool) -> [String] {
        let blocks = text.components(separatedBy: "\n\n").filter { $0.first?.isNumber == true }
        return blocks.filter { block in
            let url = block.components(separatedBy: "\n").dropFirst().first?.trimmingCharacters(in: .whitespaces) ?? ""
            let h = URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
            let on = !host.isEmpty && (h == host || h.hasSuffix("." + host))
            return sameSite ? on : !on && !h.isEmpty
        }
    }

    static func note(_ sill: Sill, lines: [String], said answer: String = "") -> String? {
        guard var kind = kind(lines) else { return nil }
        // Sill's own reason for a page it couldn't open, when the answer has it ("The site’s certificate isn’t valid…").
        if case .blocked = kind, let r = answer.range(of: #"couldn[’']t open it: ([^\n]+?)(\. Try|\n|$)"#, options: .regularExpression) {
            let reason = String(answer[r]).replacingOccurrences(of: #"^couldn[’']t open it: "#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(\. Try|\n)$"#, with: "", options: .regularExpression)
            kind = .blocked(clip(reason, 120))
        }
        let urlString = lines[1].trimmingCharacters(in: .whitespaces)
        let url = URL(string: urlString)
        let sort: String = { switch kind { case .blocked: return "blocked"; case .notFound: return "notFound"; case .empty: return "empty" } }()
        let key = urlString + "|" + sort
        guard lock.withLock({ done.insert(key).inserted }) else { return nil }
        let host = (url?.host() ?? "").replacingOccurrences(of: "www.", with: "")
        switch kind {
        case .empty(let said):
            let state = lines.first { $0.hasPrefix("State: ") }.map { " Narrowing it now: " + $0.dropFirst(7) + "." } ?? ""
            return "↪ No results here (“\(said)”).\(state) Loosen one thing at a time, the narrowest first (a filter, a date, fewer or plainer search words, the site's own spelling), before concluding it isn't there."
        case .blocked(let why), .notFound(let why):
            let blocked: Bool = { if case .blocked = kind { return true }; return false }()
            let q = words(lines, url: url)
            guard !q.isEmpty else {
                return blocked ? "↪ Dead end: \(why). Look for the same thing from another source (web_search for it), or the site's other address."
                               : "↪ Not found here: \(why). Use the site's own search, or web_search with site:\(host)."
            }
            // Blocked: the site's own name with the words, so its other storefronts, mirrors and price trackers
            // come up too (only the blocked address itself is left out). Not found: a search of that site.
            let brand = host.split(separator: ".").dropLast().last.map(String.init) ?? ""
            let query = blocked ? ((brand.count >= 3 && !q.lowercased().contains(brand.lowercased()) ? brand + " " : "") + q) : "site:\(host) \(q)"
            let found = (try? webSearch(sill, ["query": query, "count": 8])) ?? ""
            let kept = results(found, host: host, sameSite: !blocked).prefix(4)
            let head = blocked ? "↪ Dead end: \(why). The same thing elsewhere (searched “\(query)”, \(host) left out):"
                               : "↪ Not found here (“\(why)”). Where it is now on \(host) (searched “\(query)”):"
            if kept.isEmpty {
                return blocked ? "↪ Dead end: \(why). A search for “\(query)” found nothing elsewhere: try other words, or tell the user what blocked it."
                               : "↪ Not found here (“\(why)”). A search of \(host) for “\(q)” found nothing: try the site's own search or menu."
            }
            return head + "\n" + kept.enumerated().map { i, b in
                var parts = b.components(separatedBy: "\n")
                if let first = parts.first, let dot = first.firstIndex(of: ".") { parts[0] = "\(i + 1)" + first[dot...] }
                return parts.joined(separator: "\n")
            }.joined(separator: "\n")
        }
    }
}
