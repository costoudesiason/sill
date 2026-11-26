import Foundation

/// Learning a page's rhythm: when the agent does the same few actions again and again on a page (a quiz's
/// next → answer → submit, a form filled row after row), each one its own model turn, it's told the round it's
/// repeating and to send each round as one call. The model's turns are where the time goes (7 s each, median,
/// in the user's own sessions); the page's actions take a tenth of a second.
enum Rounds {
    private static let lock = NSLock()
    private static var trail: [String: [(token: String, call: Int)]] = [:]
    private static var call = 0
    private static var told: Set<String> = []

    /// What an action was, by what it acted on (never what was typed): "click “DIVE”", "type into “Your answer”".
    static func tokens(tool: String, args: [String: Any], tab: String) -> [String] {
        let lines = seen.lines(tab) ?? []
        func label(_ v: Any?) -> String {
            guard let s = v as? String, !s.isEmpty else { return "?" }
            if s.range(of: #"^(e\d+|f\d+:e\d+|a\d+)$"#, options: .regularExpression) != nil,
               let line = lines.first(where: { $0.contains("[\(s)] ") }),
               let r = line.range(of: #"\] [a-z]+ "([^"]+)""#, options: .regularExpression) {
                let parts = String(line[r]).components(separatedBy: "\"")
                if parts.count >= 2 { return "“" + clip(parts[1], 40) + "”" }
            }
            return "“" + clip(s, 40) + "”"
        }
        func step(_ s: [String: Any]) -> String? {
            if let t = s["click"] { return t is [Any] ? "click at a point" : "click " + label(t) }
            if let t = s["type"] { return "type into " + label(t) }
            if let k = s["press"] as? String { return "press " + k }
            if let t = s["select"] { return "choose in " + label(t) }
            if s["paste"] != nil { return "paste" + (s["on"].map { " into " + label($0) } ?? "") }
            if s["drag"] != nil { return "drag" }
            if s["date"] != nil { return "pick a date" }
            return nil   // waits and reads: not the round's actions
        }
        switch tool {
        case "page_do": return (args["steps"] as? [[String: Any]] ?? []).compactMap(step)
        case "page_click": return ["click " + label(args["text"] ?? args["ref"] ?? args["selector"])]
        case "page_type": return ["type into " + label(args["label"] ?? args["ref"] ?? args["selector"])]
        case "page_press": return ["press " + (args["key"] as? String ?? "?")]
        case "page_select": return ["choose in " + label(args["text"] ?? args["ref"])]
        default: return []
        }
    }

    /// Records a call's actions on a tab; if the last of them repeat a round spread over several calls, the hint.
    static func note(tool: String, args: [String: Any], tab: String) -> String? {
        let new = tokens(tool: tool, args: args, tab: tab)
        guard !new.isEmpty else { return nil }
        return lock.withLock {
            call += 1
            var t = trail[tab] ?? []
            t += new.map { ($0, call) }
            if t.count > 40 { t.removeFirst(t.count - 40) }
            trail[tab] = t
            for k in 2...6 where t.count >= 2 * k {
                let last = t.suffix(k), before = t.dropLast(k).suffix(k)
                guard last.map(\.token) == before.map(\.token), Set(last.map(\.token)).count >= 2 else { continue }
                let calls = Set(last.map(\.call)).count
                guard calls > 1 else { return nil }   // already one call a round
                let round = last.map(\.token).joined(separator: " → ")
                guard told.insert(tab + "|" + round).inserted else { return nil }
                return "↻ The same round again on this page: \(round), \(calls) calls (model turns) each time. Send each round as ONE page_do, its steps in that order with this round's answer typed in, ending with a {\"wait\": …} for words the next round always shows: the next round comes back with it, one turn a round instead of \(calls)."
            }
            return nil
        }
    }
}
