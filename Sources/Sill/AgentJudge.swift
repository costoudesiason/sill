import AppKit
import FoundationModels

// Auto mode: an agent goes ahead on its own, and Sill asks you only before a
// step that's hard to undo or speaks for you: paying, ordering, sending,
// posting, deleting, transferring. Most actions don't come near that and go
// straight through; the few whose words suggest it are put to Apple's
// on-device model (private, free, no network), which says whether this one
// needs you. Without the model, those few always ask.
//
// Settings › Agents › "Ask before" decides: risky steps (auto), every
// action that could change something, or never.

@MainActor
enum AgentJudge {
    enum Mode: String, CaseIterable {
        case auto, always, never
    }

    /// As the setting shows it.
    static func label(_ mode: String) -> String {
        switch Mode(rawValue: mode) ?? .auto {
        case .auto: return "Risky steps"
        case .always: return "Every change"
        case .never: return "Never"
        }
    }

    struct Step {
        let action: String      // "click", "press Enter", "submit"
        let target: String      // the element's name and role, as the page gives them
        let page: String        // title
        let site: String        // host
    }

    /// Words that put a step in front of the judge. Anything else goes ahead.
    private static let weighty = try! NSRegularExpression(pattern:
        #"\b(buy|purchase|pay|payment|order|checkout|check out|place|confirm|send|post|publish|tweet|reply|share|"#
        + #"delete|remove|erase|destroy|cancel|unsubscribe|subscribe|transfer|withdraw|deposit|wire|book|reserve|"#
        + #"donate|tip|sign|agree|accept|submit|apply|merge|deploy|invite|upgrade|downgrade|renew|refund|close account)\b"#,
        options: [.caseInsensitive])

    /// Pages where any submit counts: checkouts and payment forms.
    private static let paymentPage = try! NSRegularExpression(pattern: #"(checkout|payment|billing|cart|pay\b|transfer)"#,
                                                              options: [.caseInsensitive])

    private static var allowedUntil: [String: Date] = [:]   // site → don't ask again for a while

    /// Nil to go ahead; else why it was refused.
    static func clear(_ step: Step) async -> String? {
        // Read live, so `defaults write … agentAsk` (the test course) takes effect at once.
        let mode = Mode(rawValue: Preferences.shared.store.string(forKey: "agentAsk") ?? Preferences.shared.agentAsk) ?? .auto
        if mode == .never { return nil }
        if let until = allowedUntil[step.site], until > Date(), step.action != "enter card details" { return nil }
        // Card details: always asked, unless you've said never.
        if step.action == "enter card details" {
            return await ask(step, reason: "The agent wants to enter payment card details.") ? nil
                : "The user said no to entering card details on \(step.site). Ask them in chat."
        }
        let text = "\(step.action) \(step.target) \(step.page)"
        let range = NSRange(text.startIndex..., in: text)
        let weighs = weighty.firstMatch(in: text, range: range) != nil
            || (step.action != "click" && paymentPage.firstMatch(in: step.site + " " + step.page, range: NSRange(location: 0, length: (step.site + " " + step.page).utf16.count)) != nil)
        guard mode == .always || weighs else { return nil }

        var reason = "This could change something on \(step.site)."
        if mode == .auto {
            let verdict = await judge(step)
            if verdict?.needsYou == false { return nil }
            if let why = verdict?.reason, !why.isEmpty { reason = why }
        }
        return await ask(step, reason: reason) ? nil : "The user said no to: \(step.action) “\(step.target)” on \(step.site). Don't try another way to do it; ask them in chat."
    }

    // MARK: the on-device model

    @Generable
    struct Verdict {
        @Guide(description: "True if this step spends money, sends or publishes something in the user's name, deletes or cancels something, changes account or security settings, or can't be undone. False for reading, navigating, searching, filtering, opening menus, filling a form without sending it, or signing in.")
        var needsYou: Bool
        @Guide(description: "One short sentence for the user saying what the step would do, e.g. “This places the order for £42.99.”")
        var reason: String
    }

    private static func judge(_ step: Step) async -> Verdict? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        // Plain, neutral words: Apple's content filter turned the first
        // wording ("an AI agent in the user's browser") away as unsafe.
        let session = LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: "Classify a button press on a website. Say whether the person should confirm it first: yes for payments, orders, sending messages, posting, deleting, cancelling or changing an account; no for searching, browsing, filtering, cookies or opening menus.")
        let prompt = "Website: \(step.site). Page title: \(step.page). Pressing: \(step.target)."
        do {
            return try await session.respond(to: prompt, generating: Verdict.self).content
        } catch {
            return nil
        }
    }

    // MARK: asking you

    private static func ask(_ step: Step, reason: String) async -> Bool {
        let answer = await AgentAsk.ask(title: "Let the agent \(step.action) “\(step.target.prefix(60))”?",
                                        detail: "\(reason)\nOn \(step.site).",
                                        remember: step.action == "enter card details" ? nil : "Don’t ask again on \(step.site) for an hour")
        if answer.allowed, answer.remember { allowedUntil[step.site] = Date().addingTimeInterval(3600) }
        return answer.allowed
    }
}
