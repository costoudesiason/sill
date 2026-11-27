// The rule lists in this file (`unwanted`, `slots`, `slotsBySite`, `reddit`
// and `networkFilter`) are adapted from Search's Shield.swift:
// Copyright (c) 2026 Office Commun, MIT License. See NOTICE.

import CryptoKit
import WebKit

/// The ad and tracker blocker. A content rule list is enforced inside
/// WebKit's networking, before a request is made and before a stylesheet is
/// applied, so it costs pages nothing while they run, unlike a script.
///
/// It is compiled once and kept by WebKit under a name made from its rules,
/// so every later launch only looks it up: a few milliseconds. Every page
/// shares one content controller (Web.controller), so adding the list there
/// covers every tab, private window and popup at once.
@MainActor
final class Shield: ObservableObject {
    static let shared = Shield()

    private let store = WKContentRuleListStore.default()
    private var list: WKContentRuleList?
    private var identifier: String?
    /// Bumped on every compile, so an answer from an older one is ignored.
    private var generation = 0
    private var preparing = false

    /// Set when compiling failed: nothing is blocked until it's nil, which is
    /// worth saying in Settings rather than failing quietly.
    @Published private(set) var trouble: String?

    /// Sites it's off for, by bare host: the ones it broke.
    private(set) var paused: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "shield.paused") ?? [])

    private init() {}

    // MARK: - The first loads wait for it

    // The tab restored in front starts loading before the list is ready, and
    // its first requests would go out unblocked. So the first loads of a
    // launch wait for it, at most a second; after that nothing waits.
    private var held: [() -> Void] = []
    private var settled = false

    /// Runs `go` now, or once the list is ready, has failed, or a second has passed.
    func whenReady(_ go: @escaping () -> Void) {
        // On Chromium, uBlock Origin Lite blocks inside the engine from the
        // first request: nothing needs to wait for WebKit's list.
        go()
    }

    private func release() {
        settled = true
        let loads = held
        held = []
        loads.forEach { $0() }
    }

    // MARK: - On, off, paused

    func setEnabled(_ on: Bool) {
        guard let list else {
            if on, !preparing { compile() }
            return
        }
        Web.controller.remove(list)
        if on { Web.controller.add(list) }
    }

    func isPaused(on host: String?) -> Bool {
        guard let host else { return false }
        return paused.contains(Domains.bare(host))
    }

    /// Off (or back on) for one site. The list is rebuilt with it left out,
    /// which takes milliseconds for rules this few.
    /// `then` runs once the new list is in place, to reload the page under it.
    func pause(_ host: String, _ off: Bool, then: (() -> Void)? = nil) {
        let host = Domains.bare(host)
        if off { paused.insert(host) } else { paused.remove(host) }
        UserDefaults.standard.set(paused.sorted(), forKey: "shield.paused")
        if let then { afterCompile.append(then) }
        compile()
    }

    /// Waiting for the list being compiled now, whichever way it ends.
    private var afterCompile: [() -> Void] = []

    private func finished() {
        let waiting = afterCompile
        afterCompile = []
        waiting.forEach { $0() }
    }

    func tryAgain() {
        trouble = nil
        compile()
    }

    // MARK: - Compiling

    func compile() {
        guard let data = try? JSONSerialization.data(withJSONObject: rules(), options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            trouble = "Couldn’t build the block list"
            release()
            finished()
            return
        }
        // The sorted JSON is both what WebKit compiles and the name of its
        // compiled form: the same rules are never compiled twice.
        let id = "sill-shield-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard id != identifier || list == nil else { return finished() }
        guard let store else {
            trouble = "WebKit has nowhere to keep the block list"
            release()
            finished()
            return
        }
        generation += 1
        let mine = generation
        preparing = true
        store.lookUpContentRuleList(forIdentifier: id) { [weak self] found, _ in
            MainActor.assumeIsolated {
                guard let self, mine == self.generation else { return }
                if let found { return self.ready(found, id: id) }
                store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { [weak self] compiled, error in
                    MainActor.assumeIsolated {
                        guard let self, mine == self.generation else { return }
                        guard let compiled else {
                            self.preparing = false
                            self.trouble = error?.localizedDescription ?? "Compiling the block list failed"
                            self.release()
                            self.finished()
                            return
                        }
                        self.ready(compiled, id: id)
                    }
                }
            }
        }
    }

    private func ready(_ compiled: WKContentRuleList, id: String) {
        preparing = false
        trouble = nil
        if let list { Web.controller.remove(list) }
        list = compiled
        identifier = id
        if Preferences.shared.blocksAds { Web.controller.add(compiled) }
        release()
        finished()
        // Lists from older rules go; anyone else's in WebKit's store stay.
        store?.getAvailableContentRuleListIdentifiers { [store] identifiers in
            for old in identifiers ?? [] where old != id && old.hasPrefix("sill-shield-") {
                store?.removeContentRuleList(forIdentifier: old) { _ in }
            }
        }
    }

    // MARK: - The rules

    /// Sites the blocker leaves alone: YouTube (it walls off pages that block
    /// its ads, and it's where videos float from) and whatever was paused.
    private var exempt: [String] {
        ["youtube.com", "youtube-nocookie.com"] + paused.sorted()
    }

    private func rules() -> [[String: Any]] {
        let exempt = exempt
        // A site list with the exempt sites taken out.
        func without(_ sites: [String]) -> [String] {
            sites.filter { site in
                let domain = site.hasPrefix("*") ? String(site.dropFirst()) : site
                return !exempt.contains { $0 == domain || $0.hasSuffix("." + domain) || domain.hasSuffix("." + $0) }
            }
        }

        var rules: [[String: Any]] = Self.unwanted.map { domain in
            ["trigger": ["url-filter": Self.networkFilter(for: domain), "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        // Hiding rules are left out on exempt sites directly, as well as by
        // the rule at the end, so they are sure not to apply there.
        rules.append([
            "trigger": ["url-filter": ".*", "unless-domain": exempt.map { "*" + $0 }],
            "action": ["type": "css-display-none", "selector": Self.slots.joined(separator: ", ")],
        ])
        for entry in Self.slotsBySite {
            let sites = without(entry.sites)
            guard !sites.isEmpty else { continue }
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": sites],
                "action": ["type": "css-display-none", "selector": entry.selector],
            ])
        }
        let reddit = without(["*reddit.com"])
        if !reddit.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": reddit],
                "action": ["type": "css-display-none", "selector": Self.reddit.joined(separator: ", ")],
            ])
        }
        // Last: on an exempt site, nothing above applies, its third parties included.
        rules.append([
            "trigger": ["url-filter": ".*", "if-domain": exempt.map { "*" + $0 }],
            "action": ["type": "ignore-previous-rules"],
        ])
        return rules
    }

    /// Third parties whose only job is to watch or to sell. First-party
    /// requests are untouched: a site's own scripts are the site.
    private static let unwanted = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "googletagservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "adnxs.com", "adsrvr.org",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
        "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "smartadserver.com", "sharethrough.com", "indexww.com", "bidswitch.net",
        "33across.com", "teads.tv", "moatads.com", "adroll.com",
        "scorecardresearch.com", "quantserve.com", "chartbeat.com",
        "hotjar.com", "mouseflow.com", "fullstory.com", "clarity.ms",
        "mixpanel.com", "amplitude.com", "segment.com", "segment.io",
        "branch.io", "appsflyer.com", "adjust.com", "analytics.tiktok.com",
        "connect.facebook.net", "ads-twitter.com", "analytics.twitter.com",
    ]

    /// The few slots that are reliably an advertisement and nothing else,
    /// kept short: a generous cosmetic list is how a blocker starts eating
    /// the page. The second half are the boxes a site keeps open for an ad
    /// while it loads, whole class names from EasyList's generic hiding list.
    private static let slots = [
        ".adsbygoogle", "ins.adsbygoogle", "[id^=\"google_ads_\"]",
        "[id^=\"div-gpt-ad\"]", "[id^=\"taboola-\"]", "#taboola-below-article",
        "iframe[src*=\"doubleclick.net\"]", "iframe[src*=\"googlesyndication\"]",
        "iframe[src*=\"amazon-adsystem\"]",
        ".ad-slot", ".ad-slot-container", ".top-banner-ad-container",
        ".ad-leaderboard", ".ad-billboard", ".ad-giga", ".ad-mpu", ".ad-mrec",
        ".ad-unit", ".adunit", ".adslot", ".dfp-ad", ".gpt-ad", ".w_ad",
    ]

    /// Slots with names too plain, or too much a site's own, to hide
    /// everywhere, hidden only on the sites they belong to.
    private static let slotsBySite: [(sites: [String], selector: String)] = [
        (["*as.com", "*elpais.com"], ".ad"),
        (["*theguardian.com"], ".top-fronts-banner-ad-container"),
        (["*independent.co.uk", "*the-independent.com"], "#billboard-wrapper"),
        (["*cnn.com"], ".ad-slot-header__wrapper"),
    ]

    /// Reddit's own promoted posts: custom elements in its light DOM. A
    /// normal post is a `shreddit-post`, never one of these.
    private static let reddit = [
        "shreddit-ad-post", "shreddit-comments-page-ad", "shreddit-sidebar-ad",
        "shreddit-dynamic-ad-link", "comment-tree-ad", ".promotedlink",
    ]

    static func networkFilter(for domain: String) -> String {
        let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
        // WebKit's canonical HTTP URLs end the host with a port or a slash.
        return "^https?://([^/]+\\.)?\(escaped)[:/]"
    }
}
