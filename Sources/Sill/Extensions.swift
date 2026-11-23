import AppKit
import OpenDirectory
import CryptoKit
import SwiftUI

/// The extensions that come with Sill on Chromium (uBlock Origin Lite), as
/// the engine installed them in the profile (SillEngine.mm, InstallExtensions).
struct InstalledExtension: Identifiable, Equatable {
    /// The folder's name: what the on/off setting is kept under.
    let folder: String
    /// Chromium's ID for it, from where it is (an extension loaded from a folder).
    let id: String
    let name: String
    let version: String
    let summary: String
    let icon: NSImage?
    /// Its own pages, relative to the extension: the toolbar popup and its settings.
    let popup: String?
    let options: String?

    static func == (a: Self, b: Self) -> Bool { a.folder == b.folder && a.version == b.version }

    func page(_ path: String) -> URL? { URL(string: "chrome-extension://\(id)/\(path.trimmingCharacters(in: ["/"]))") }
}

enum Extensions {
    static var folder: URL { Places.support.appendingPathComponent("Extensions") }

    /// Switched off in the panel; the engine leaves them out when it starts.
    static var disabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "disabledExtensions") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "disabledExtensions") }
    }

    static func installed() -> [InstalledExtension] {
        let files = FileManager.default
        let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.sorted().compactMap { load(folder.appendingPathComponent($0)) }
    }

    private static func load(_ dir: URL) -> InstalledExtension? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let messages = localized(dir, locale: manifest["default_locale"] as? String)
        func text(_ key: String) -> String {
            let raw = manifest[key] as? String ?? ""
            guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__") else { return raw }
            let name = String(raw.dropFirst(6).dropLast(2)).lowercased()
            return messages[name] ?? raw
        }
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        let options = (manifest["options_page"] as? String) ?? ((manifest["options_ui"] as? [String: Any])?["page"] as? String)
        return InstalledExtension(folder: dir.lastPathComponent, id: id(for: dir), name: text("name"),
                                  version: manifest["version"] as? String ?? "", summary: text("description"),
                                  icon: icon(dir, manifest), popup: action?["default_popup"] as? String, options: options)
    }

    /// An unpacked extension's ID: the SHA-256 of its folder's path, its
    /// first 16 bytes written with the letters a–p (Chromium's id_util).
    static func id(for dir: URL) -> String {
        let digest = SHA256.hash(data: Data(dir.path.utf8))
        return digest.prefix(16).map { byte in
            String([Character(UnicodeScalar(97 + Int(byte >> 4))!), Character(UnicodeScalar(97 + Int(byte & 15))!)])
        }.joined()
    }

    private static func localized(_ dir: URL, locale: String?) -> [String: String] {
        let preferred = [Locale.current.identifier, Locale.current.language.languageCode?.identifier, locale, "en"].compactMap { $0 }
        for code in preferred {
            let file = dir.appendingPathComponent("_locales/\(code)/messages.json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { continue }
            var out: [String: String] = [:]
            for (key, value) in json { if let message = value["message"] as? String { out[key.lowercased()] = message } }
            return out
        }
        return [:]
    }

    private static func icon(_ dir: URL, _ manifest: [String: Any]) -> NSImage? {
        guard let icons = manifest["icons"] as? [String: String] else { return nil }
        // The smallest at least 32 px, else the biggest there is.
        var sized: [(size: Int, path: String)] = []
        for (key, path) in icons { if let size = Int(key) { sized.append((size, path)) } }
        sized.sort { $0.size < $1.size }
        guard let path = (sized.first { $0.size >= 32 } ?? sized.last)?.path else { return nil }
        return NSImage(contentsOf: dir.appendingPathComponent(path))
    }

    /// Quits and opens Sill again, for a change the engine only reads as it starts.
    static func relaunch() {
        let app = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - uBlock Origin Lite's per-site setting

/// uBlock Origin Lite's filtering mode for a site, read and set through the
/// messages its own popup sends. Its popup can't be used in Sill: it asks
/// Chromium which tab is in front, and Chromium doesn't know Sill's tabs.
/// The messages go from one of its own pages, kept loaded out of sight.
@MainActor
final class UBlock {
    static let shared = UBlock()
    static let folder = "uBlock Origin Lite"
    /// The modes, as its popup names them: 0 none … 3 complete.
    static let levels = ["Off", "Basic", "Optimal", "Complete"]

    private var page: SillWebView?
    private var ready: [CheckedContinuation<Void, Never>] = []
    private var loaded = false

    var installed: InstalledExtension? {
        Extensions.installed().first { $0.folder == Self.folder && !Extensions.disabled.contains($0.folder) }
    }

    private func connect() async -> SillWebView? {
        if let page, loaded { return page }
        guard let item = installed, let url = item.page("popup.html") else { return nil }
        if page == nil {
            let view = SillWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), private: false)
            view.loadURL(url)
            page = view
        }
        // Its script API is there once the page has started: ask until it answers.
        for _ in 0..<40 {
            if let answer = try? await page?.callAsyncJavaScript("return typeof chrome?.runtime?.sendMessage", contentWorld: .page),
               answer as? String == "function" { loaded = true; return page }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func level(for host: String) async -> Int? {
        guard let page = await connect() else { return nil }
        let value = try? await page.callAsyncJavaScript(
            "return await chrome.runtime.sendMessage({ what: 'getFilteringMode', hostname: host })",
            arguments: ["host": host], contentWorld: .page)
        return (value as? NSNumber)?.intValue ?? (value as? Int)
    }

    func set(_ level: Int, for host: String) async -> Int? {
        guard let page = await connect() else { return nil }
        let value = try? await page.callAsyncJavaScript(
            "return await chrome.runtime.sendMessage({ what: 'setFilteringMode', hostname: host, level })",
            arguments: ["host": host, "level": level], contentWorld: .page)
        return (value as? NSNumber)?.intValue ?? (value as? Int)
    }
}

// MARK: - The panel

/// The Extensions button's panel: what's installed, each on or off, and a
/// way into each one's own controls.
struct ExtensionsView: View {
    let open: (URL) -> Void
    /// The site in front, for uBlock Origin Lite's per-site mode; reloaded when it changes.
    let site: String?
    let reload: () -> Void
    @State private var level: Int?
    @State private var items = Extensions.installed()
    @State private var disabled = Extensions.disabled
    private let atLaunch = Extensions.disabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Extensions").font(.headline).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if items.isEmpty {
                Text("No extensions installed.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                VStack(spacing: 2) { ForEach(items) { row($0) } }.padding(.horizontal, 8).padding(.bottom, 8)
                if let site, items.contains(where: { $0.folder == UBlock.folder }), !atLaunch.contains(UBlock.folder) {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Blocking on \(Domains.bare(site))").font(.callout).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { level ?? -1 }, set: { new in
                            let before = level
                            level = new
                            Task {
                                let now = await UBlock.shared.set(new, for: site)
                                level = now ?? before
                                if now != before { reload() }
                            }
                        })) {
                            ForEach(UBlock.levels.indices, id: \.self) { Text(UBlock.levels[$0]).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .disabled(level == nil)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .task { level = await UBlock.shared.level(for: site) }
                }
            }
            if disabled != atLaunch {
                Divider()
                HStack {
                    Text("Takes effect when Sill restarts.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart") { Extensions.relaunch() }.keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .frame(width: 340)
    }

    private func row(_ item: InstalledExtension) -> some View {
        let on = !disabled.contains(item.folder)
        return HStack(spacing: 10) {
            Group {
                if let icon = item.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "puzzlepiece.extension") }
            }
            .frame(width: 28, height: 28)
            .opacity(on ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.body).lineLimit(1)
                Text("Version \(item.version)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let options = item.options, on, let url = item.page(options) {
                Button { open(url) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Settings")
            }
            Toggle("", isOn: Binding(get: { on }, set: { value in
                if value { disabled.remove(item.folder) } else { disabled.insert(item.folder) }
                Extensions.disabled = disabled
            }))
            .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Profile


/// Who is browsing: the Mac account's name and picture.
enum Profile {
    static var name: String {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }

    /// The picture of this Mac account, as Users & Groups shows it: kept in
    /// the local directory, else the picture file it names.
    private static let accountPicture: NSImage? = {
        let node: ODNode, record: ODRecord
        do {
            node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(),
                                     attributes: [kODAttributeTypeJPEGPhoto, kODAttributeTypePicture])
        } catch {
            return nil
        }
        if let data = (try? record.values(forAttribute: kODAttributeTypeJPEGPhoto))?.first as? Data, let image = NSImage(data: data) {
            return image
        }
        if let path = (try? record.values(forAttribute: kODAttributeTypePicture))?.first as? String { return NSImage(contentsOfFile: path) }
        return nil
    }()

    /// The account picture, round, at `size` points; initials on a tinted
    /// circle where there is none.
    static func picture(size: CGFloat) -> NSImage {
        let photo = accountPicture
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect)
            if let photo {
                circle.addClip()
                photo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                NSColor.controlAccentColor.setFill()
                circle.fill()
                let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size * 0.4, weight: .semibold), .foregroundColor: NSColor.white,
                    .paragraphStyle: style,
                ]
                let height = (letters as NSString).size(withAttributes: attributes).height
                (letters as NSString).draw(in: NSRect(x: 0, y: (size - height) / 2, width: size, height: height), withAttributes: attributes)
            }
            return true
        }
    }
}
