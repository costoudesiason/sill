import AppKit
import Combine
import Security

// claude.ai driving Sill. claude.ai calls connectors from Anthropic's cloud,
// so it can't reach this Mac directly: a small relay on the internet (relay/
// in this repository, on Railway) is the connector's address, and Sill's
// helper (sill-mcp --relay) dials out to it and keeps the line open. Each
// tool call comes down that line to Sill's local agent socket, as Claude
// Code's would. A new sign-in to the connector waits for you to click Allow
// in Sill (ConnectorApproval).
//
// Settings › Agents › "Let claude.ai control Sill". The relay's address is
// kept in preferences, its key in the Keychain.

@MainActor
final class ConnectorBridge: ObservableObject {
    static let shared = ConnectorBridge()

    enum State: Equatable {
        case off, connecting, connected
        case failed(String)
    }

    @Published private(set) var state: State = .off
    private var process: Process?
    private var watching: [AnyCancellable] = []
    private var retry: DispatchWorkItem?
    private var quitting: Any?
    private var waking: Any?

    func follow(_ prefs: Preferences) {
        let changed: (Any) -> Void = { [weak self] _ in DispatchQueue.main.async { self?.update() } }
        watching = [prefs.$agentControl.sink(receiveValue: changed),
                    prefs.$remoteConnector.sink(receiveValue: changed),
                    prefs.$connectorRelay.sink(receiveValue: changed)]
        // Back from sleep (a lid opened): a fresh line at once, not after the
        // helper's next try, so claude.ai finds Sill again within a second.
        waking = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                   queue: .main) { _ in
            MainActor.assumeIsolated { ConnectorBridge.shared.restart() }
        }
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { ConnectorBridge.shared.stop() }
        }
    }

    /// The connector's address, for claude.ai: the relay's /mcp.
    static var connectorAddress: String? {
        relayOrigin.map { $0 + "/mcp" }
    }

    static var relayOrigin: String? {
        let text = Preferences.shared.connectorRelay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "https://" + text),
              url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1",
              let host = url.host, !host.isEmpty else { return nil }
        return "\(url.scheme ?? "https")://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }

    private var wanted: Bool {
        let prefs = Preferences.shared
        return prefs.agentControl && prefs.remoteConnector && Self.relayOrigin != nil && ConnectorKey.read() != nil
    }

    func update() {
        if wanted { start() } else { stop() }
    }

    /// After the address or key changed: a fresh line with the new ones.
    func restart() {
        stop()
        update()
    }

    private func start() {
        guard process == nil, let origin = Self.relayOrigin, let key = ConnectorKey.read() else { return }
        retry?.cancel()
        let bridge = origin.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + "/bridge"
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: SettingsSupport.mcpHelper)
        helper.arguments = ["--relay", bridge]
        var environment = ProcessInfo.processInfo.environment
        environment["SILL_RELAY_SECRET"] = key   // not in its arguments, where `ps` would show it
        environment["SILL_SOCKET"] = AgentServer.socketURL.path
        environment["SILL_RELAY_NOT_BEFORE"] = String(Int(Preferences.shared.connectorNotBefore))
        helper.environment = environment
        let output = Pipe()
        helper.standardOutput = output
        helper.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                for line in text.split(separator: "\n") { ConnectorBridge.shared.heard(String(line)) }
            }
        }
        helper.terminationHandler = { [weak helper] _ in
            DispatchQueue.main.async {
                let bridge = ConnectorBridge.shared
                guard let helper, bridge.process === helper else { return }
                output.fileHandleForReading.readabilityHandler = nil
                bridge.process = nil
                guard bridge.wanted else { bridge.state = .off; return }
                bridge.state = .failed("Restarting…")
                let again = DispatchWorkItem { ConnectorBridge.shared.update() }
                bridge.retry = again
                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: again)
            }
        }
        do {
            try helper.run()
            process = helper
            state = .connecting
        } catch {
            state = .failed("Sill’s helper couldn’t start.")
        }
    }

    func stop() {
        retry?.cancel()
        retry = nil
        let helper = process
        process = nil
        helper?.terminate()
        state = .off
    }

    /// The helper reports on its line: "connected", "disconnected: why", "refused: why".
    private func heard(_ line: String) {
        if line == "connected" { state = .connected }
        else if line.hasPrefix("refused") { state = .failed("The relay turned the key down.") }
        else if line.hasPrefix("disconnected") { state = .connecting }
    }

    var summary: String {
        switch state {
        case .off: return Self.relayOrigin == nil || ConnectorKey.read() == nil ? "Needs a relay" : "Off"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let why): return why
        }
    }
}

extension ConnectorBridge {
    /// Every claude.ai sign-in so far stops working: the relay is told, on a
    /// fresh line, to turn away tokens from before now. Adding the connector
    /// again asks you to Allow it again.
    func signEveryoneOut() {
        Preferences.shared.connectorNotBefore = Date().timeIntervalSince1970
        restart()
    }
}

/// The relay's key: what lets this Mac attach to it. In the login Keychain.
enum ConnectorKey {
    private static let service = "app.sill.connector"
    private static let account = "relay"

    static func read() -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String) {
        let match: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let data = Data(key.utf8)
        if SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var add = match
            add[kSecValueData] = data
            add[kSecAttrLabel] = "Sill: claude.ai connector relay"
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Where the relay is, and its key: asked in one small dialog.
@MainActor
enum ConnectorSetup {
    static func run() {
        let alert = NSAlert()
        alert.messageText = "Connect Sill to your relay"
        alert.informativeText = "Your relay’s address, and the key it was started with (its RELAY_SECRET). The key is kept in your Keychain."
        let address = NSTextField(string: Preferences.shared.connectorRelay)
        address.placeholderString = "https://sill-relay.up.railway.app"
        let key = NSSecureTextField(string: "")
        key.placeholderString = ConnectorKey.read() == nil ? "Relay key" : "Unchanged"
        let stack = NSStackView(views: [address, key])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 52)
        for field in [address, key] { field.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = address
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Preferences.shared.connectorRelay = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { ConnectorKey.save(typed) }
        ConnectorBridge.shared.restart()
    }
}
