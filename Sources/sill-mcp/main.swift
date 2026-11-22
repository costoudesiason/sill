// sill-mcp: the Sill browser for any MCP client (Claude Code, Codex, Cursor…).
//
//     claude mcp add sill -- /Applications/Sill.app/Contents/Helpers/sill-mcp
//
// Turn on Settings › Agents › "Allow agents to control Sill" first. Sill then
// listens on agent.sock in ~/Library/Application Support/Sill, for this user
// only, and this server passes each tool call there as one JSON line and
// returns the answer. Everything that matters is decided in Sill. See
// AGENTS.md for the commands.

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Sill/agent.sock").path
let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

// MARK: - Tools

struct Tool {
    let name: String
    let command: String
    let description: String
    let properties: [String: [String: Any]]
    let required: [String]
}

let tabProperty: [String: Any] = ["type": "string", "description": "Tab id from tabs_list. Omit for the tab in front."]
let targetProperties: [String: [String: Any]] = [
    "tab": tabProperty,
    "ref": ["type": "string", "description": "Element ref from page_snapshot (e.g. \"e12\"). Preferred."],
    "selector": ["type": "string", "description": "CSS selector, if no ref."],
    "text": ["type": "string", "description": "Visible text or accessible name of the element, if no ref or selector."],
]

let tools: [Tool] = [
    Tool(name: "status", command: "status",
         description: "Check that Sill is running and agent control is on. Returns app version and window/tab counts.",
         properties: [:], required: []),
    Tool(name: "tabs_list", command: "tabs.list",
         description: "List open tabs in Sill's normal windows (private windows are never shown): id, url, title, loading, selected, asleep, openedByAgent.",
         properties: [:], required: []),
    Tool(name: "tabs_open", command: "tabs.open",
         description: "Open an http(s) address (or a bare domain like example.com) in a new tab and, by default, wait until it has loaded. Returns the new tab.",
         properties: ["url": ["type": "string", "description": "Address to open."],
                      "background": ["type": "boolean", "description": "Open without bringing the tab to the front. Default false."],
                      "wait": ["type": "boolean", "description": "Wait for load. Default true."],
                      "timeout": ["type": "number", "description": "Seconds to wait. Default 20."]],
         required: ["url"]),
    Tool(name: "tabs_select", command: "tabs.select", description: "Bring a tab to the front (needed for real clicks, keys and screenshots).",
         properties: ["tab": tabProperty], required: ["tab"]),
    Tool(name: "tabs_close", command: "tabs.close", description: "Close a tab.", properties: ["tab": tabProperty], required: ["tab"]),
    Tool(name: "page_navigate", command: "page.navigate",
         description: "Load an http(s) address in a tab (default: the tab in front) and wait for it to load.",
         properties: ["tab": tabProperty, "url": ["type": "string", "description": "Address to load."],
                      "wait": ["type": "boolean"], "timeout": ["type": "number"]],
         required: ["url"]),
    Tool(name: "page_back", command: "page.back", description: "Go back in a tab's history and wait for the page.", properties: ["tab": tabProperty], required: []),
    Tool(name: "page_forward", command: "page.forward", description: "Go forward in a tab's history and wait for the page.", properties: ["tab": tabProperty], required: []),
    Tool(name: "page_reload", command: "page.reload", description: "Reload a tab and wait for the page.", properties: ["tab": tabProperty], required: []),
    Tool(name: "page_wait", command: "page.wait",
         description: "Wait until the page has loaded, or until a CSS selector exists, or until some text appears.",
         properties: ["tab": tabProperty, "selector": ["type": "string"], "text": ["type": "string"],
                      "timeout": ["type": "number", "description": "Seconds. Default 20."]],
         required: []),
    Tool(name: "page_text", command: "page.text",
         description: "The page's visible text (document.body.innerText), with its url and title.",
         properties: ["tab": tabProperty, "maxChars": ["type": "integer", "description": "Default 40000."]], required: []),
    Tool(name: "page_snapshot", command: "page.snapshot",
         description: "Interactive elements on the page (links, buttons, fields, selects, checkboxes, ARIA widgets) with a stable ref, role, accessible name, value (never a password's), href, checked/disabled/focused and a viewport box in CSS pixels. Use the refs with page_click / page_type / page_select. By default only elements near the viewport; all=true for the whole page.",
         properties: ["tab": tabProperty, "all": ["type": "boolean"]], required: []),
    Tool(name: "page_click", command: "page.click",
         description: "Click an element (scrolled into view first). Uses a real mouse click when the tab is in front, else a script click.",
         properties: targetProperties.merging(["double": ["type": "boolean", "description": "Double-click."],
                                               "real": ["type": "boolean", "description": "Default true."]]) { a, _ in a },
         required: []),
    Tool(name: "page_type", command: "page.type",
         description: "Type text into a field or contenteditable element, replacing what's there unless clear=false; submit=true presses Enter afterwards.",
         properties: ["tab": tabProperty,
                      "ref": ["type": "string", "description": "Field ref from page_snapshot. Preferred."],
                      "selector": ["type": "string", "description": "CSS selector, if no ref."],
                      "label": ["type": "string", "description": "The field's label, placeholder or accessible name, if no ref or selector."],
                      "text": ["type": "string", "description": "The text to type."],
                      "clear": ["type": "boolean", "description": "Replace what's there. Default true."],
                      "submit": ["type": "boolean", "description": "Press Enter afterwards."]],
         required: ["text"]),
    Tool(name: "page_select", command: "page.select",
         description: "Choose an option in a <select> by its value or visible label.",
         properties: targetProperties.merging(["value": ["type": "string"]]) { a, _ in a }, required: ["value"]),
    Tool(name: "page_press", command: "page.press",
         description: "Press a key in the tab in front: Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp, ArrowDown, ArrowLeft, ArrowRight, PageUp, PageDown, Home, End.",
         properties: ["tab": tabProperty, "key": ["type": "string"]], required: ["key"]),
    Tool(name: "page_scroll", command: "page.scroll",
         description: "Scroll the page by dy CSS pixels (negative goes up), or scroll an element (ref/selector/text) into view.",
         properties: targetProperties.merging(["dy": ["type": "number"]]) { a, _ in a }, required: []),
    Tool(name: "page_eval", command: "page.eval",
         description: "Run JavaScript in the page as an async function body and return its JSON value (use `return`).",
         properties: ["tab": tabProperty, "script": ["type": "string"]], required: ["script"]),
    Tool(name: "page_screenshot", command: "page.screenshot",
         description: "A PNG of the tab's visible page. Best on the tab in front.",
         properties: ["tab": tabProperty, "maxWidth": ["type": "number", "description": "Scale down to this width in points."]], required: []),
    Tool(name: "page_find", command: "page.find", description: "Find text on the page and scroll to it.",
         properties: ["tab": tabProperty, "text": ["type": "string"]], required: ["text"]),
    Tool(name: "history_search", command: "history.search",
         description: "Search the user's Sill history (or recent pages if query is empty).",
         properties: ["query": ["type": "string"], "limit": ["type": "integer"]], required: []),
]

// MARK: - Sill's socket

final class Sill {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextID = 1

    private func connect() throws {
        if fd >= 0 { return }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw Failure("Couldn't make a socket.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes.prefix(buffer.count - 1))
            buffer[min(bytes.count, buffer.count - 1)] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(s)
            throw Failure("Sill isn't listening. Open Sill and turn on Settings › Agents › “Allow agents to control Sill”.")
        }
        _ = fcntl(s, F_SETNOSIGPIPE, 1)
        fd = s
    }

    func call(_ command: String, _ args: [String: Any]) throws -> [String: Any] {
        do { return try send(command, args) } catch {
            // One retry on a fresh connection: Sill may have restarted.
            close(fd); fd = -1; buffer = Data()
            return try send(command, args)
        }
    }

    private func send(_ command: String, _ args: [String: Any]) throws -> [String: Any] {
        try connect()
        let id = nextID
        nextID += 1
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "cmd": command, "args": args])
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { throw Failure("Lost the connection to Sill.") }
                sent += n
            }
        }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let answer = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if (answer["id"] as? Int) == id { return answer }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { throw Failure("Sill closed the connection.") }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - MCP over stdio

let sill = Sill()

func reply(_ id: Any, result: Any) {
    write(["jsonrpc": "2.0", "id": id, "result": result])
}

func reply(_ id: Any, error code: Int, _ message: String) {
    write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func write(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

func schema(_ tool: Tool) -> [String: Any] {
    ["type": "object", "properties": tool.properties, "required": tool.required, "additionalProperties": false]
}

func handle(_ message: [String: Any]) {
    let method = message["method"] as? String ?? ""
    guard let id = message["id"] else { return }   // a notification: nothing to say
    switch method {
    case "initialize":
        let asked = (message["params"] as? [String: Any])?["protocolVersion"] as? String
        let version = asked.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0]
        reply(id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "sill", "version": "0.3"],
            "instructions": "Drives the Sill web browser on this Mac. Start with tabs_list or tabs_open, then page_snapshot to get element refs, and act with page_click / page_type / page_select / page_press. page_text reads the page. Private windows are never visible.",
        ])
    case "ping":
        reply(id, result: [String: Any]())
    case "tools/list":
        reply(id, result: ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": schema($0)] }])
    case "tools/call":
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        guard let tool = tools.first(where: { $0.name == name }) else {
            reply(id, error: -32602, "Unknown tool \(name)")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let answer = try sill.call(tool.command, arguments)
            if answer["ok"] as? Bool == true {
                let result = answer["result"] ?? NSNull()
                if tool.name == "page_screenshot", let image = result as? [String: Any], let png = image["png"] as? String {
                    reply(id, result: ["content": [["type": "image", "data": png, "mimeType": "image/png"]]])
                } else {
                    let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .fragmentsAllowed])) ?? Data()
                    reply(id, result: ["content": [["type": "text", "text": String(data: data, encoding: .utf8) ?? ""]]])
                }
            } else {
                reply(id, result: ["content": [["type": "text", "text": answer["error"] as? String ?? "Sill refused."]], "isError": true])
            }
        } catch let failure as Failure {
            reply(id, result: ["content": [["type": "text", "text": failure.message]], "isError": true])
        } catch {
            reply(id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    default:
        reply(id, error: -32601, "Method not found: \(method)")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    handle(message)
}
