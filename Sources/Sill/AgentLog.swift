import AppKit
import SwiftUI

// What agents did, kept so you can look: every command, when, where, by
// whom (this Mac or claude.ai), and how it went. Never what was typed, no
// passwords, no page contents: "typed 12 characters", "signed in as …".
// One JSON line each in agent-log.jsonl, the last 2,000 kept.

@MainActor
enum AgentLog {
    struct Entry: Identifiable, Codable {
        var id = UUID()
        let at: Date
        let via: String       // "local" or "claude.ai"
        let action: String
        let detail: String
        let site: String
        let ok: Bool
        let note: String
    }

    private static var url: URL { Places.support.appendingPathComponent("agent-log.jsonl") }
    private static var written = 0

    static func record(command: String, args: [String: Any], result: Any?, error: String?) {
        // Reads of the page are frequent and change nothing: kept out, so the log is what was done.
        guard !["page.snapshot", "page.text", "page.screenshot", "tabs.list", "status", "page.wait", "passwords.list"].contains(command)
        else { return }
        let r = result as? [String: Any] ?? [:]
        let url = (r["url"] as? String) ?? (args["url"] as? String) ?? ""
        let entry = Entry(at: Date(), via: args["_via"] as? String == "relay" ? "claude.ai" : "local",
                          action: command, detail: detail(command, args, r), site: URL(string: url)?.host ?? "",
                          ok: error == nil, note: error.map { String($0.prefix(160)) } ?? "")
        guard let line = try? JSONEncoder().encode(entry) else { return }
        let path = self.url.path
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line + Data([0x0A]))
            try? handle.close()
        }
        written += 1
        if written % 200 == 0 { trim() }
    }

    private static func detail(_ command: String, _ args: [String: Any], _ result: [String: Any]) -> String {
        func s(_ key: String) -> String? { (args[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch command {
        case "tabs.open", "page.navigate": return s("url") ?? ""
        case "page.click", "page.hover": return (result["name"] as? String) ?? s("ref") ?? s("text") ?? s("selector") ?? "a point"
        case "page.type": return "typed \((args["text"] as? String)?.count ?? 0) characters\(args["submit"] as? Bool == true ? " and sent" : "")"
        case "page.press": return s("key") ?? ""
        case "page.select": return "chose \(s("value") ?? "")"
        case "page.signin": return "signed in as \(result["signedInAs"] as? String ?? "?")"
        case "passwords.save": return "saved a password for \(s("user") ?? "?")"
        case "page.upload": return "uploaded \((result["uploaded"] as? [String])?.joined(separator: ", ") ?? "")"
        case "page.eval": return "ran a script (\((args["script"] as? String)?.count ?? 0) characters)"
        case "page.dialog": return (args["accept"] as? Bool ?? true) ? "accepted the page's dialog" : "dismissed the page's dialog"
        case "user.wait": return "asked you: \(s("message") ?? "")"
        default: return ""
        }
    }

    static func recent(_ count: Int = 500) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).suffix(count).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }.reversed()
    }

    private static func trim() {
        guard let data = try? Data(contentsOf: url) else { return }
        let lines = data.split(separator: 0x0A)
        guard lines.count > 2000 else { return }
        let kept = lines.suffix(2000).map { Data($0) + Data([0x0A]) }.reduce(Data(), +)
        try? kept.write(to: url, options: .atomic)
    }

    static func clear() { try? Data().write(to: url, options: .atomic) }

    // MARK: the window

    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let made = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        made.title = "Agent Activity"
        made.isReleasedWhenClosed = false
        made.contentView = NSHostingView(rootView: AgentLogView())
        made.center()
        made.makeKeyAndOrderFront(nil)
        window = made
    }
}

private struct AgentLogView: View {
    @State private var entries = AgentLog.recent()
    private let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .medium; return f }()

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("Nothing yet. What agents do in Sill shows here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: entry.ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(entry.ok ? Color.secondary : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.action.replacingOccurrences(of: ".", with: " "))  \(entry.detail)").lineLimit(2)
                            Text([time.string(from: entry.at), entry.site, entry.via == "claude.ai" ? "from claude.ai" : nil,
                                  entry.note.isEmpty ? nil : entry.note].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Button("Clear") { AgentLog.clear(); entries = [] }
                Spacer()
                Button("Refresh") { entries = AgentLog.recent() }
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 300)
    }
}

/// A question for you about an agent's next step, in a small card in the
/// corner of the screen: it doesn't take the keyboard, cover your window or
/// bring Sill forward. Answered with Allow or Don't Allow.
@MainActor
enum AgentAsk {
    static func ask(title: String, detail: String, allow: String = "Allow", remember: String? = nil) async -> (allowed: Bool, remember: Bool) {
        NSApp.requestUserAttention(.informationalRequest)
        return await withCheckedContinuation { continuation in
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            var answered = false
            let finish: (Bool, Bool) -> Void = { allowed, keep in
                guard !answered else { return }
                answered = true
                panel.orderOut(nil)
                continuation.resume(returning: (allowed, keep))
            }
            let view = AgentAskView(title: title, detail: detail, allow: allow, remember: remember, answer: finish)
            let host = NSHostingView(rootView: view)
            panel.contentView = host
            panel.setContentSize(host.fittingSize)
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - panel.frame.width - 16, y: screen.maxY - 12))
            }
            panel.orderFrontRegardless()
        }
    }
}

private struct AgentAskView: View {
    let title: String, detail: String, allow: String
    let remember: String?
    let answer: (Bool, Bool) -> Void
    @State private var keep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(3)
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let remember { Toggle(remember, isOn: $keep).toggleStyle(.checkbox).font(.system(size: 11)) }
            HStack {
                Spacer()
                Button("Don’t Allow") { answer(false, false) }.keyboardShortcut(.cancelAction)
                Button(allow) { answer(true, keep) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
