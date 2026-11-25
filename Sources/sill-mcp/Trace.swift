import Foundation

/// A record of a run for graders, kept only when SILL_TRACE_DIR is set (the benchmarks):
/// after each action, a picture of the tab it acted in and what the action was, in order,
/// as Online-Mind2Web's and WebVoyager's judges read them. The agent is never shown any of it.
enum Trace {
    static let dir: URL? = ProcessInfo.processInfo.environment["SILL_TRACE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    private static let lock = NSLock()
    private static var count = 0

    /// Tools that look things up without acting in a page: nothing to picture.
    static let quiet: Set<String> = ["status", "tabs_list", "history_search", "files", "passwords_list", "wait_for_user", "page_do", "page_goal"]

    static func record(_ sill: Sill, tab: Any?, action: String, result: String? = nil) {
        guard let dir else { return }
        var args: [String: Any] = ["maxWidth": 1280, "quality": 0.7, "remember": false]
        if let tab { args["tab"] = tab }
        let shot = (try? sill.run("page.screenshot", args)) as? [String: Any]
        let data = (shot?["data"] as? String).flatMap { Data(base64Encoded: $0) }
        let url = ((try? sill.run("page.text", (tab.map { ["tab": $0] } ?? [:]).merging(["maxChars": 1, "remember": false]) { $1 })) as? [String: Any])?["url"] as? String
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        count += 1
        var step: [String: Any] = ["step": count, "action": action, "at": Date().timeIntervalSince1970]
        if let url { step["url"] = url }
        if let result { step["result"] = String(result.prefix(600)) }
        if let data {
            let name = "\(count).jpg"
            try? data.write(to: dir.appendingPathComponent(name))
            step["screenshot"] = name
        }
        guard let line = try? JSONSerialization.data(withJSONObject: step), let file = dir.appendingPathComponent("steps.jsonl").path.cString(using: .utf8) else { return }
        let fd = open(file, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        _ = write(fd, "\n", 1)
        close(fd)
    }

    /// An action as a grader reads it: the tool and its arguments, short.
    static func describe(_ name: String, _ args: [String: Any]) -> String {
        let shown = args.filter { !["snapshot", "full", "remember"].contains($0.key) }
        let json = (try? JSONSerialization.data(withJSONObject: shown, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return name + " " + String(json.prefix(400))
    }
}
