import AppKit
import CommonCrypto
import Foundation
import Security
import SQLite3

/// Passwords Sill keeps, as Chrome keeps its own: one Keychain item per
/// account and site, in your login keychain (encrypted by macOS, readable by
/// Sill without asking again once allowed). Sill never writes a password to
/// a file of its own.
///
/// Items are internet passwords for the site's host, marked as Sill's with
/// the creator code 'SILL', so they show in Keychain Access as "Sill: host".
enum SavedPasswords {
    struct Login: Hashable {
        let host: String
        let user: String
    }

    fileprivate static let creator = FourCharCode(0x5349_4C4C)  // 'SILL'

    fileprivate static func base(_ host: String, _ user: String) -> [String: Any] {
        [kSecClass as String: kSecClassInternetPassword,
         kSecAttrServer as String: host,
         kSecAttrAccount as String: user,
         kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
         kSecAttrCreator as String: creator]
    }

    /// Every account Sill has for `host` or its site (accounts.google.com
    /// matches google.com), exact host first. Names only: no password is read.
    static func logins(for host: String) async -> [Login] {
        let site = Domains.registrable(host)
        if TestPasswords.on {
            let all = TestPasswords.all().map { Login(host: $0.host, user: $0.user) }
            return all.filter { $0.host == host || Domains.registrable($0.host) == site }.sorted { $0.user < $1.user }
        }
        return await Task.detached(priority: .userInitiated) { () -> [Login] in
            let query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                        kSecAttrCreator as String: creator,
                                        kSecMatchLimit as String: kSecMatchLimitAll,
                                        kSecReturnAttributes as String: true]
            var found: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
                  let items = found as? [[String: Any]] else { return [] }
            let all = items.compactMap { item -> Login? in
                guard let server = item[kSecAttrServer as String] as? String,
                      let user = item[kSecAttrAccount as String] as? String else { return nil }
                return Login(host: server, user: user)
            }
            let mine = all.filter { $0.host == host || Domains.registrable($0.host) == site }
            return mine.sorted { ($0.host == host ? 0 : 1, $0.user) < ($1.host == host ? 0 : 1, $1.user) }
        }.value
    }

    /// The password of one account, read only when it's being filled.
    static func password(for login: Login) async -> String? {
        if TestPasswords.on { return TestPasswords.get(login.host, login.user) }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            var query = base(login.host, login.user)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
                  let data = found as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    enum Saved { case added, updated, same, failed }

    /// Sites you've said never to save passwords for (their registrable domain).
    static func never(for host: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: "neverSavePasswords") ?? []).contains(Domains.registrable(host))
    }
    static func setNever(for host: String) {
        var sites = Set(UserDefaults.standard.stringArray(forKey: "neverSavePasswords") ?? [])
        sites.insert(Domains.registrable(host))
        UserDefaults.standard.set(sites.sorted(), forKey: "neverSavePasswords")
    }

    /// Keeps `password` for `user` at `host`: a new item, or the existing one updated.
    @discardableResult
    static func save(_ password: String, user: String, host: String) async -> Saved {
        await Task.detached(priority: .userInitiated) { () -> Saved in
            store(password, user: user, host: host)
        }.value
    }

    fileprivate static func store(_ password: String, user: String, host: String) -> Saved {
        if TestPasswords.on { return TestPasswords.set(host, user, password) }
        let data = Data(password.utf8)
        var read = base(host, user)
        read[kSecReturnData as String] = true
        var existing: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &existing)
        if status == errSecSuccess {
            if (existing as? Data) == data { return .same }
            let changed = SecItemUpdate(base(host, user) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            return changed == errSecSuccess ? .updated : .failed
        }
        var add = base(host, user)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Sill: \(host)"
        add[kSecAttrComment as String] = "Saved by Sill"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? .added : .failed
    }

    /// Whether `password` is already what Sill has for `user` at `host`
    /// (nothing to ask), different (asks to update), or not saved (asks to save).
    static func state(_ password: String, user: String, host: String) async -> Saved {
        if TestPasswords.on { return TestPasswords.get(host, user).map { $0 == password ? .same : .updated } ?? .added }
        return await Task.detached(priority: .userInitiated) { () -> Saved in
            var read = base(host, user)
            read[kSecReturnData as String] = true
            var existing: CFTypeRef?
            guard SecItemCopyMatching(read as CFDictionary, &existing) == errSecSuccess else { return .added }
            return (existing as? Data) == Data(password.utf8) ? .same : .updated
        }.value
    }
}

// MARK: - Import from Dia

/// Dia's saved passwords into Sill. Dia keeps them as Chrome does: in a
/// SQLite file in its profile, each password encrypted (AES-128-CBC) with a
/// key derived from a secret in your login keychain, "Dia Safe Storage".
/// macOS asks you once whether Sill may read that secret. Everything happens
/// in Sill, in memory; the decrypted passwords go straight into the Keychain.
enum DiaImport {
    private static let profile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dia/User Data/Default")

    static var available: Bool {
        FileManager.default.fileExists(atPath: profile.appendingPathComponent("Login Data").path)
    }

    enum Outcome { case imported(added: Int, updated: Int, skipped: Int), noAccess, nothing, failed(String) }

    static func run() async -> Outcome {
        await Task.detached(priority: .userInitiated) { () -> Outcome in
            guard let key = safeStorageKey() else { return .noAccess }
            var rows: [(url: String, user: String, blob: Data)] = []
            for name in ["Login Data", "Login Data For Account"] {
                rows += read(profile.appendingPathComponent(name))
            }
            guard !rows.isEmpty else { return .nothing }
            var added = 0, updated = 0, skipped = 0
            var seen = Set<String>()
            for row in rows {
                guard let host = URL(string: row.url)?.host(), let password = decrypt(row.blob, key: key), !password.isEmpty,
                      seen.insert("\(host)\u{0}\(row.user)").inserted else { skipped += 1; continue }
                switch SavedPasswords.store(password, user: row.user, host: host) {
                case .added: added += 1
                case .updated: updated += 1
                case .same: skipped += 1
                case .failed: skipped += 1
                }
            }
            return .imported(added: added, updated: updated, skipped: skipped)
        }.value
    }

    /// The secret Dia encrypts with; reading it is what macOS asks you about.
    private static func safeStorageKey() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "Dia Safe Storage",
                                    kSecAttrAccount as String: "Dia",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let secret = found as? Data else { return nil }
        // Chrome's key: PBKDF2-HMAC-SHA1 of the secret, salt "saltysalt", 1003 rounds, 16 bytes.
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { out in
            secret.withUnsafeBytes { pass in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress?.assumingMemoryBound(to: CChar.self), secret.count,
                                         s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                         out.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// Its logins table, read from a copy (Dia holds the file open while it runs).
    private static func read(_ file: URL) -> [(url: String, user: String, blob: Data)] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("sill-dia-\(UUID().uuidString).db")
        guard (try? FileManager.default.copyItem(at: file, to: copy)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: copy) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [(String, String, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let url = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let user = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let length = Int(sqlite3_column_bytes(statement, 2))
            guard length > 0, let bytes = sqlite3_column_blob(statement, 2) else { continue }
            out.append((url, user, Data(bytes: bytes, count: length)))
        }
        return out
    }

    /// "v10" + AES-128-CBC, IV of 16 spaces, PKCS#7 padding.
    private static func decrypt(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = blob.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var plain = Data(count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let status = plain.withUnsafeMutableBytes { out in
            cipher.withUnsafeBytes { input in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, input.baseAddress, cipher.count,
                                out.baseAddress, out.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: plain.prefix(written), encoding: .utf8)
    }
}

extension SavedPasswords {
    /// Every account Sill keeps, by site then name. Names only.
    static func all() async -> [Login] {
        if TestPasswords.on { return TestPasswords.all().map { Login(host: $0.host, user: $0.user) } }
        return await Task.detached(priority: .userInitiated) { () -> [Login] in
            let query: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                        kSecAttrCreator as String: creator,
                                        kSecMatchLimit as String: kSecMatchLimitAll,
                                        kSecReturnAttributes as String: true]
            var found: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
                  let items = found as? [[String: Any]] else { return [] }
            return items.compactMap { item -> Login? in
                guard let server = item[kSecAttrServer as String] as? String,
                      let user = item[kSecAttrAccount as String] as? String else { return nil }
                return Login(host: server, user: user)
            }
            .sorted { (Domains.bare($0.host), $0.user) < (Domains.bare($1.host), $1.user) }
        }.value
    }

    @discardableResult
    static func delete(_ login: Login) async -> Bool {
        await Task.detached(priority: .userInitiated) { () -> Bool in
            SecItemDelete(base(login.host, login.user) as CFDictionary) == errSecSuccess
        }.value
    }
}


/// A test copy of Sill (the course, the benchmarks) is re-signed on every build, and the keychain asks
/// about every re-signed copy: its passwords are a file in its own profile instead (test values only).
enum TestPasswords {
    static let on = Places.testProfile != nil
    private static let lock = NSLock()
    private static var file: URL { Places.support.appendingPathComponent("passwords-test.json") }

    private static func read() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
    }

    static func all() -> [(host: String, user: String)] {
        lock.withLock { read().keys.compactMap { key in
            let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        } }
    }

    static func get(_ host: String, _ user: String) -> String? { lock.withLock { read()[host + "\n" + user] } }

    static func set(_ host: String, _ user: String, _ password: String) -> SavedPasswords.Saved {
        lock.withLock {
            var all = read()
            let key = host + "\n" + user
            let before = all[key]
            all[key] = password
            guard let data = try? JSONEncoder().encode(all), (try? data.write(to: file, options: .atomic)) != nil else { return .failed }
            return before == nil ? .added : before == password ? .same : .updated
        }
    }
}
