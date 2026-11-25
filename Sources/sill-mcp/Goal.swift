// page_goal: a fast model drives the routine steps, Claude decides the rest.
//
// Claude is slow per step (seconds of thinking, a round trip through claude.ai
// and the relay) and wasted on "which of these 40 links is the search box".
// TypeSafe's Jev answers typed questions about a state in 70–500 ms: given
// the goal, the page's elements and what's been done, it picks the next
// action and the element. This loop asks it, acts through Sill, and repeats,
// all on this Mac, with no round trip to Claude between steps. It hands back
// to Claude when the goal's met, when Jev is unsure, when it goes round in
// circles, and always before a step that pays, sends, posts, deletes or
// commits (Claude asks the user in chat).
//
// The key: TYPESAFE_API_KEY, else the Keychain item "Sill TypeSafe". Without
// one, page_goal isn't listed. What Jev sees: the goal, the page's title and
// address, its headings, and each element's role and name. Never what's in a
// field, never a password; the values Claude gives to type are sent.

import Foundation
import Security

enum Jev {
    static let key: String? = {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Sill TypeSafe",
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }()

    /// One request: the answers by question id.
    static func ask(state: Any, questions: [String: Any]) throws -> [String: [String: Any]] {
        guard let key else { throw Failure("No TypeSafe key.") }
        // TYPESAFE_URL: a stand-in for tests.
        let endpoint = ProcessInfo.processInfo.environment["TYPESAFE_URL"] ?? "https://api.typesafe.ai/v1/systemone"
        var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "jev-latest", "state": state, "questions": questions])
        let done = DispatchSemaphore(value: 0)
        var body: Data?, failure: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = error.localizedDescription }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                failure = "Jev answered \(http.statusCode): \(String(data: data ?? Data(), encoding: .utf8)?.prefix(200) ?? "")"
            } else { body = data }
            done.signal()
        }.resume()
        done.wait()
        if let failure { throw Failure(failure) }
        guard let body, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let answers = json["answers"] as? [String: [String: Any]] else { throw Failure("Jev gave no answers.") }
        return answers
    }
}

/// Words that make a click or a submit the user's to decide.
private let weighty = try! NSRegularExpression(pattern:
    #"\b(buy|purchase|pay|payment|order|checkout|check out|place|confirm|send|post|publish|tweet|reply|share|"#
    + #"delete|remove|erase|cancel|unsubscribe|subscribe|transfer|withdraw|deposit|book|reserve|donate|"#
    + #"sign up|agree|accept terms|submit|apply|invite|upgrade|renew|refund|close account)\b"#, options: [.caseInsensitive])

private func isWeighty(_ text: String) -> Bool {
    weighty.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

let goalTool = Tool(
    name: "page_goal",
    description: """
Hand a routine goal on the page to a fast model that drives Sill step by step on the Mac (a fraction of a second \
per step, no round trips to you): "search for Alan Turing and open his article", "open the Orders page, then the \
latest order". Give the text it may type in `values` (e.g. {"query": "Alan Turing"}): it never makes text up. It \
stops and hands back when the goal is met, when it's unsure (with the candidates), when it would repeat itself, and \
before any step that pays, sends, posts, deletes or commits (ask the user, then do it yourself with page_do). \
Answers with the steps taken and the page as it is now. For one or two steps you can already see, page_do is quicker.
""",
    properties: ["tab": tabProperty,
                 "goal": ["type": "string", "description": "What should be true when it's done, in plain words."],
                 "values": ["type": "object", "additionalProperties": ["type": "string"], "description": "Text it may type, by what it's for."],
                 "max_steps": ["type": "integer", "description": "Default 12, at most 25."]],
    required: ["goal"]) { sill, args in [.text(try runGoal(sill, args))] }

func runGoal(_ sill: Sill, _ args: [String: Any]) throws -> String {
    guard let goal = (args["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else { throw Failure("Give a \"goal\".") }
    let values = (args["values"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
    let budget = max(1, min(args["max_steps"] as? Int ?? 12, 25))
    var tab: [String: Any] = [:]
    if let t = args["tab"] { tab["tab"] = t }
    var done: [String] = [], lines: [String] = []
    var recent: [String] = []
    var thinking = 0.0
    let started = Date()
    var outcome = "Stopped after \(budget) steps without reaching the goal: look at the page and carry on yourself."

    for _ in 1...budget {
        let snapshot = try sill.run("page.snapshot", tab)
        let page = snapshot as? [String: Any] ?? [:]
        let all = page["elements"] as? [[String: Any]] ?? []
        let context = all.compactMap { $0["context"] != nil ? clip($0["text"] as? String ?? "", 120) : nil }.prefix(20)
        var names: [String: String] = [:]
        var options: [String: String] = [:]
        for element in all where options.count < 80 {
            guard let ref = element["ref"] as? String else { continue }
            var line = element["role"] as? String ?? "element"
            if let name = element["name"] as? String, !name.isEmpty { line += " “\(clip(name, 80))”" }
            if let href = element["href"] as? String, let url = URL(string: href) { line += " → \(clip(url.path, 60))" }
            if element["disabled"] as? Bool == true { continue }
            options[ref] = line
            names[ref] = line
        }
        if options.isEmpty { outcome = "Nothing on the page to act on: look at it yourself (page_read)."; break }

        var questions: [String: Any] = [
            "goal_met": ["type": "noul", "instructions": "The goal has already been fully achieved: the page now shows what the goal asks for."],
            "action": ["type": "choice", "instructions": "The single next action that best moves toward the goal.",
                       "criteria": ["click": "Click an element: a link, button, tab, option, checkbox or menu",
                                    "type": "Type one of the available values into a text field or search box",
                                    "scroll": "Scroll down: what's needed isn't among the elements yet",
                                    "stop": "Nothing to do: the goal is reached, or can't be reached from this page"]],
            "element": ["type": "choice", "instructions": "The element the next action should be done on.", "criteria": options],
        ]
        if !values.isEmpty {
            questions["value"] = ["type": "choice", "instructions": "Which available value to type next.",
                                  "criteria": values.mapValues { "Type “\($0)”" }]
            questions["enter"] = ["type": "noul", "instructions": "After typing that value, pressing Enter is the next step toward the goal (a search box, a single-field form)."]
        }
        let state: [String: Any] = ["goal": goal, "page": "\(page["title"] as? String ?? "") — \(page["url"] as? String ?? "")",
                                    "done_so_far": done.isEmpty ? ["nothing yet"] : done, "headings_and_messages": Array(context)]
        let t0 = Date()
        let answers = try Jev.ask(state: state, questions: questions)
        thinking += Date().timeIntervalSince(t0)

        let action = answers["action"]?["choice"] as? String ?? "stop"
        if (answers["goal_met"]?["noul"] as? Double ?? 0) >= 0.7 || action == "stop" {
            outcome = (answers["goal_met"]?["noul"] as? Double ?? 0) >= 0.5 ? "Goal reached." : "It went as far as it could: look at the page and carry on yourself."
            break
        }
        let tookMs = { Int(Date().timeIntervalSince(t0) * 1000) }
        if action == "scroll" {
            _ = try sill.run("page.scroll", tab.merging(["dy": 700]) { $1 })
            done.append("scrolled down")
            lines.append("\(lines.count + 1). scrolled down (\(tookMs()) ms)")
            continue
        }
        let element = answers["element"] ?? [:]
        let ref = element["choice"] as? String ?? ""
        let confidence = element["confidence"] as? Double ?? 0
        guard let name = names[ref] else { outcome = "The fast model picked nothing usable: carry on yourself."; break }
        if confidence < 0.3 {
            let top = (element["probabilities"] as? [String: Double] ?? [:]).sorted { $0.value > $1.value }.prefix(3)
                .map { "\(names[$0.key] ?? $0.key) (\($0.key), \(Int($0.value * 100))%)" }
            outcome = "Unsure what to \(action) next. Candidates: \(top.joined(separator: "; ")). Decide, then use page_do."
            break
        }
        let signature = "\(action) \(ref)"
        recent.append(signature)
        if recent.count >= 4, recent.suffix(4).allSatisfy({ $0 == signature }) {
            outcome = "It would \(action) \(name) (\(ref)) again: it's going round in circles. Carry on yourself."
            break
        }

        if action == "type" {
            let which = answers["value"]?["choice"] as? String ?? values.keys.first ?? ""
            guard let text = values[which] else { outcome = "It wants to type, but there's no value for it: give `values`, or type with page_do."; break }
            let enter = (answers["enter"]?["noul"] as? Double ?? 0) >= 0.6
            if enter, isWeighty(name + " " + (page["title"] as? String ?? "")) {
                outcome = "Next would be typing “\(text)” into \(name) (\(ref)) and pressing Enter, which may send or commit something. Ask the user, then do it with page_do."
                break
            }
            _ = try sill.run("page.type", tab.merging(["ref": ref, "text": text, "submit": enter]) { $1 })
            done.append("typed “\(text)” into \(name)\(enter ? " and pressed Enter" : "")")
        } else {
            if isWeighty(name) {
                outcome = "Next would be clicking \(name) (\(ref)), which may pay, send, post, delete or commit. Ask the user, then do it with page_do."
                break
            }
            let r = try sill.run("page.click", tab.merging(["ref": ref]) { $1 }) as? [String: Any] ?? [:]
            if let missed = r["missed"] as? String { outcome = missed; break }
            if let opened = r["opened"] as? [String: Any], let id = opened["id"] { tab["tab"] = id }
            done.append("clicked \(name)")
        }
        lines.append("\(lines.count + 1). \(done.last!) (\(tookMs()) ms)")
    }

    var out = ["\(outcome) \(lines.count) step(s) in \(Int(Date().timeIntervalSince(started) * 1000)) ms (the fast model's share: \(Int(thinking * 1000)) ms)."]
    out += lines
    if let snapshot = try? sill.run("page.snapshot", tab) { out += ["", listing(snapshot, full: false)] }
    return out.joined(separator: "\n")
}
