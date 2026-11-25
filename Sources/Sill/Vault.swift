import Foundation
import Security

/// Secrets an agent can use without ever seeing them, and without macOS asking
/// mid-task: passwords and keys for named sites, and the keys Sill's own
/// helpers need (TypeSafe's). One item in your login keychain, made and read by
/// Sill itself (so it's never asked about), holding them all; kept in memory once
/// read. An agent asks Sill to fill one into a field; Sill does it only on the
/// sites the secret is for, so a page that talks an agent round can't send a key
/// elsewhere. Only Sill's helpers on this Mac (never claude.ai's calls) can read
/// a key meant for them.
@MainActor
enum AgentVault {
    struct Entry: Codable {
        var name: String
        /// "password", "key", "card", "service" (for Sill's helpers), "note".
        var kind: String
        var value: String
        /// Where it may be filled: hosts like "github.com" (subdomains count). Empty: nowhere (a service key).
        var sites: [String] = []
        var user: String?
    }

    private static let service = "Sill Vault", account = "vault"
    private static var cache: [String: Entry]?

    /// A test copy of Sill (the course, the benchmarks) is re-signed on every build, so the keychain would
    /// ask about it each time: its vault is a file in its own profile instead, holding test values only.
    private static var testFile: URL? { Places.testProfile == nil ? nil : Places.support.appendingPathComponent("vault-test.json") }

    private static func load() -> [String: Entry] {
        if let cache { return cache }
        if let file = testFile {
            let list = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
            cache = Dictionary(list.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { $1 })
            return cache ?? [:]
        }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var found: CFTypeRef?
        var entries: [String: Entry] = [:]
        if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            for e in list { entries[e.name.lowercased()] = e }
        }
        cache = entries
        return entries
    }

    private static func store(_ entries: [String: Entry]) {
        cache = entries
        guard let data = try? JSONEncoder().encode(Array(entries.values)) else { return }
        if let file = testFile { try? data.write(to: file, options: [.atomic, .completeFileProtection]); return }
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        if SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var add = match
            add[kSecValueData] = data
            add[kSecAttrLabel] = "Sill: vault"
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Names, kinds and sites: never values.
    static func list(for host: String? = nil) -> [[String: Any]] {
        load().values.filter { host == nil || allowed($0, on: host!) }.sorted { $0.name < $1.name }.map {
            var out: [String: Any] = ["name": $0.name, "kind": $0.kind, "sites": $0.sites]
            if let user = $0.user { out["user"] = user }
            return out
        }
    }

    static func allowed(_ entry: Entry, on host: String) -> Bool {
        let h = host.lowercased()
        return entry.sites.contains { site in let s = site.lowercased(); return h == s || h.hasSuffix("." + s) }
    }

    static func entry(_ name: String) -> Entry? { load()[name.lowercased()] }

    static func set(_ entry: Entry) {
        var all = load()
        all[entry.name.lowercased()] = entry
        store(all)
    }

    static func remove(_ name: String) {
        var all = load()
        all[name.lowercased()] = nil
        store(all)
    }
}
