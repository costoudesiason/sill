import Foundation

/// What agents' own runs teach Sill about each site, so the next plan can predict
/// instead of probing: the addresses its searches build (learned when a typed query
/// shows up in the address that follows), and how long its pages take to answer an
/// action. Kept on this Mac beside history; nothing typed is kept but the shape of
/// the address, with the query replaced by {query}.
@MainActor
final class SiteNotes {
    static let shared = SiteNotes()

    struct Note: Codable {
        /// Search addresses with {query}, and how often each was seen.
        var searches: [String: Int] = [:]
        /// How long actions took to settle here, latest last (ms).
        var settles: [Int] = []
        var last = Date()
        /// The last route an agent took on this site, as steps without the values it typed.
        var route: [String]? = nil
    }

    /// The route an agent is taking now, per tab, and on which site.
    private var trail: [ObjectIdentifier: (host: String, steps: [String])] = [:]

    /// A step that worked: kept as part of this site's route, the typed words left out.
    func did(_ tab: Tab, url: URL?, click name: String? = nil, typeInto field: String? = nil) {
        guard let host = Self.host(url), !tab.isPrivate else { return }
        let key = ObjectIdentifier(tab)
        var t: (host: String, steps: [String]) = trail[key].flatMap { $0.host == host ? $0 : nil } ?? (host: host, steps: [])
        let recent = typed[key]?.text.lowercased()
        let step: String
        if let field { step = "type into “\(field.prefix(40))”" }
        else if let name, !name.isEmpty {
            step = recent.map { !$0.isEmpty && name.lowercased().contains($0) } == true ? "choose the suggestion that matches"
                 : name.count > 50 || name.rangeOfCharacter(from: .decimalDigits) != nil && name.count > 3 ? "click a result" : "click “\(name)”"
        } else { return }
        if t.steps.last != step { t.steps.append(step) }
        if t.steps.count > 14 { t.steps.removeFirst(t.steps.count - 14) }
        trail[key] = t
        if t.steps.count >= 2 {
            var note = notes[host] ?? Note()
            note.route = t.steps
            note.last = Date()
            notes[host] = note
            saver.save { [notes] in notes }
        }
    }

    private(set) var notes: [String: Note] = [:]
    /// The last text an agent typed, per tab, to spot it in the next address.
    private var typed: [ObjectIdentifier: (text: String, at: Date)] = [:]
    private let saver = Saver<[String: Note]>(Places.support.appendingPathComponent("site-notes.json"), delay: 5)

    private init() {
        if let data = try? Data(contentsOf: Places.support.appendingPathComponent("site-notes.json")),
           let read = try? JSONDecoder().decode([String: Note].self, from: data) { notes = read }
    }

    private static func host(_ url: URL?) -> String? { url?.host().map { Domains.bare($0.lowercased()) } }

    func agentTyped(_ text: String, in tab: Tab) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 120 else { return }
        typed[ObjectIdentifier(tab)] = (t, Date())
    }

    /// After an agent's action settled: how long it took, and whether the address now carries what was typed.
    func settled(_ tab: Tab, url: URL?, ms: Int) {
        guard let url, let host = Self.host(url), !tab.isPrivate else { return }
        var note = notes[host] ?? Note()
        note.settles.append(ms)
        if note.settles.count > 30 { note.settles.removeFirst(note.settles.count - 30) }
        note.last = Date()
        if let t = typed[ObjectIdentifier(tab)], Date().timeIntervalSince(t.at) < 15, let template = Self.template(url, typed: t.text) {
            note.searches[template, default: 0] += 1
            typed[ObjectIdentifier(tab)] = nil
            if note.searches.count > 4, let least = note.searches.min(by: { $0.value < $1.value })?.key { note.searches[least] = nil }
        }
        notes[host] = note
        if notes.count > 2000, let oldest = notes.min(by: { $0.value.last < $1.value.last })?.key { notes[oldest] = nil }
        saver.save { [notes] in notes }
    }

    /// The address with the typed query as {query}, other query values kept only if short (a category, a sort).
    static func template(_ url: URL, typed: String) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = parts.queryItems else {
            // A query in the path (/search/lamp)
            let path = url.path
            guard let range = path.range(of: typed.replacingOccurrences(of: " ", with: "-"), options: .caseInsensitive)
                    ?? path.range(of: typed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? typed, options: .caseInsensitive) else { return nil }
            return "\(url.scheme ?? "https")://\(url.host() ?? "")" + path.replacingCharacters(in: range, with: "{query}")
        }
        let want = typed.lowercased()
        var found = false
        parts.queryItems = items.compactMap { item in
            guard let value = item.value else { return nil }
            if !found, value.lowercased() == want || value.lowercased().replacingOccurrences(of: "+", with: " ") == want {
                found = true
                return URLQueryItem(name: item.name, value: "{query}")
            }
            return value.count <= 24 && !value.contains("%") ? item : nil   // tracking tokens and session ids go
        }
        guard found else { return nil }
        parts.fragment = nil
        return parts.string?.replacingOccurrences(of: "%7Bquery%7D", with: "{query}")
    }

    /// For the plan: this site's search address and its pace.
    func brief(for host: String) -> [String: Any] {
        guard let note = notes[Domains.bare(host.lowercased())] else { return [:] }
        var out: [String: Any] = [:]
        if let best = note.searches.max(by: { $0.value < $1.value }) { out["search"] = best.key }
        if let route = note.route, route.count >= 2 { out["route"] = route.joined(separator: " → ") }
        if note.settles.count >= 3 {
            let sorted = note.settles.sorted()
            out["settleMs"] = sorted[sorted.count / 2]
        }
        return out
    }
}
