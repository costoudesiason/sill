import AppKit
import AVFoundation
import SwiftUI
import Translation

/// A page's right-click menu, in Sill's glass menu as every menu in Sill
/// is: built from what the click landed on (a link, a picture, a video,
/// words, a field), with only what can be done there and then. Nothing
/// greyed out, nothing that does nothing on a page.
@MainActor
enum PageMenu {
    static func show(_ context: SEContextMenu, for tab: Tab, in view: SillWebView) {
        guard let window = view.window, window.isVisible else { return }
        let entries = build(context, tab, view)
        guard !entries.isEmpty else { return }
        if let path = Dump.path, path != "show" {
            Dump.write(entries, to: path)
            // SILL_MENU_PICK: the item to run, as if chosen.
            if let pick = ProcessInfo.processInfo.environment["SILL_MENU_PICK"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) })?
                .trimmingCharacters(in: .whitespacesAndNewlines), !pick.isEmpty {
                for case .item(let item) in entries where item.title == pick { item.run() }
            }
            return
        }
        GlassMenu(title: nil, entries: entries, searchable: false).show(in: window, at: context.point, from: nil)
    }

    // MARK: - What goes in

    private static func build(_ c: SEContextMenu, _ tab: Tab, _ view: SillWebView) -> [GlassMenu.Entry] {
        var entries: [GlassMenu.Entry] = []
        var section: [GlassMenu.Item] = []
        func flush() {
            guard !section.isEmpty else { return }
            if !entries.isEmpty { entries.append(.separator) }
            entries += section.map { .item($0) }
            section = []
        }
        func add(_ title: String, _ symbol: String?, keys: [String] = [], on: Bool = false, _ run: @escaping () -> Void) {
            section.append(GlassMenu.Item(title: title, symbol: symbol, keys: keys, isOn: on, run: run))
        }

        let link = c.linkURL.flatMap { ["http", "https", "mailto"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let web = { (url: URL) in ["http", "https"].contains(url.scheme?.lowercased() ?? "") }
        // Chromium selects a link's words when it's right-clicked; as in
        // Safari, the link's menu stays the link's. A password field's
        // selection is only dots, and nothing to look up or speak.
        var selection = c.selection
        if link != nil, !c.editable { selection = "" }
        if !selection.isEmpty, selection.allSatisfy({ $0 == "•" || $0 == "●" }) { selection = "" }
        let hasSelection = !selection.isEmpty
        let edit = c.editState

        // A misspelled word: Chromium's guesses first, as in Safari.
        if c.editable, c.misspelledWord != nil, !c.suggestions.isEmpty {
            for guess in c.suggestions.prefix(5) { add(guess, nil) { c.replaceMisspelling(guess) } }
            add("Learn Spelling", "text.book.closed") { c.learnSpelling() }
            flush()
        }

        // A link.
        if let link {
            if web(link) {
                add("Open Link in New Tab", "plus.square.on.square") { open(link, from: tab, background: true) }
                add("Open Link in New Window", "macwindow") { openWindow(link, isPrivate: tab.isPrivate) }
                if !tab.isPrivate {
                    add("Open Link in Private Window", "hand.raised") { openWindow(link, isPrivate: true) }
                }
                flush()
                add("Download Linked File", "arrow.down.circle") { view.startDownload(link) }
                add("Copy Link", "link") { Pasteboard.copy(link) }
                add("Share…", "square.and.arrow.up") { share([link], c, in: view) }
            } else {
                let address = String(link.absoluteString.dropFirst("mailto:".count))
                    .components(separatedBy: "?").first?.removingPercentEncoding ?? ""
                add("Write Email", "envelope") { NSWorkspace.shared.open(link) }
                add("Copy Email Address", "doc.on.doc") { copy(text: address) }
            }
            flush()
        }

        // A picture.
        if c.mediaKind == .image, let source = c.sourceURL, web(source) || source.scheme == "data" {
            if web(source) { add("Open Image in New Tab", "photo.on.rectangle") { open(source, from: tab, background: true) } }
            add("Save Image to Downloads", "square.and.arrow.down") { view.startDownload(source) }
            add("Save Image As…", "square.and.arrow.down.on.square") { saveAs(source, from: tab, in: view) }
            add("Copy Image", "photo") { copyImage(source, c) }
            if web(source) { add("Copy Image Address", "link") { Pasteboard.copy(source) } }
            if link == nil, web(source) { add("Share…", "square.and.arrow.up") { share([source], c, in: view) } }
            flush()
        }

        // A video or a sound.
        if c.mediaKind == .video || c.mediaKind == .audio, let source = c.sourceURL {
            let state = c.mediaState
            let video = c.mediaKind == .video
            let paused = state.contains(.paused)
            add(paused ? "Play" : "Pause", paused ? "play.fill" : "pause.fill") {
                media(c, source, "m.paused ? m.play() : m.pause()")
            }
            if state.contains(.hasAudio) || !video {
                let muted = state.contains(.muted)
                add(muted ? "Unmute" : "Mute", muted ? "speaker.wave.2" : "speaker.slash") { media(c, source, "m.muted = !m.muted") }
            }
            if state.contains(.canLoop) {
                add("Loop", "repeat", on: state.contains(.loops)) { media(c, source, "m.loop = !m.loop") }
            }
            if state.contains(.canToggleControls) {
                add(state.contains(.showsControls) ? "Hide Controls" : "Show Controls", "slider.horizontal.below.rectangle") {
                    media(c, source, "m.controls = !m.controls")
                }
            }
            flush()
            if video {
                // Sill's float takes a video that's playing with its sound on.
                if Floating.shared.tab === tab, Floating.shared.isFloating {
                    add("Exit Picture in Picture", "pip.exit") { PictureInPicture.return(to: tab) }
                } else if !paused, !state.contains(.muted) {
                    add("Picture in Picture", "pip.enter") { PictureInPicture.leave(tab) { _ in } }
                }
                add("Enter Full Screen", "arrow.up.left.and.arrow.down.right") {
                    media(c, source, "(m.requestFullscreen ? m.requestFullscreen() : m.webkitEnterFullscreen())")
                }
                flush()
            }
            if web(source) {
                let noun = video ? "Video" : "Audio"
                if state.contains(.canSave) {
                    add("Download \(noun)", "arrow.down.circle") { saveAs(source, from: tab, in: view) }
                }
                add("Copy \(noun) Address", "link") { Pasteboard.copy(source) }
                flush()
            }
        }

        // Words chosen: look them up, translate them, search for them.
        if hasSelection {
            let short = selection.count > 22 ? String(selection.prefix(20)) + "…" : selection
            let quoted = short.replacingOccurrences(of: "\n", with: " ")
            add("Look Up “\(quoted)”", "character.book.closed") { lookUp(selection, c, in: view) }
            add("Translate “\(quoted)”", "translate") { translate(selection, c, in: view) }
            let engine = Preferences.shared.engine
            add("Search with \(engine.name)", "magnifyingglass") { open(engine.search(selection), from: tab, background: false) }
            flush()
        }

        // Editing: what the field allows now.
        if c.editable {
            if edit.contains(.canCut) { add("Cut", "scissors", keys: ["⌘", "X"]) { c.edit("cut") } }
            if edit.contains(.canCopy) { add("Copy", "doc.on.doc", keys: ["⌘", "C"]) { c.edit("copy") } }
            if edit.contains(.canPaste) {
                add("Paste", "doc.on.clipboard", keys: ["⌘", "V"]) { c.edit("paste") }
                if edit.contains(.rich) {
                    add("Paste and Match Style", "doc.on.clipboard", keys: ["⌥", "⇧", "⌘", "V"]) { c.edit("pasteAndMatchStyle") }
                }
            }
            if edit.contains(.canSelectAll), !hasSelection {
                add("Select All", "selection.pin.in.out", keys: ["⌘", "A"]) { c.edit("selectAll") }
            }
            flush()
            // A notes editor: its own Bold, Italic and Underline (the keys,
            // so Google Docs or Notion does it as it would for you).
            if edit.contains(.rich) {
                add("Bold", "bold", keys: ["⌘", "B"]) { press("b", in: view) }
                add("Italic", "italic", keys: ["⌘", "I"]) { press("i", in: view) }
                add("Underline", "underline", keys: ["⌘", "U"]) { press("u", in: view) }
                flush()
            }
            if hasSelection {
                add("Make Upper Case", "textformat.size.larger") { replace(selection.uppercased(), in: view) }
                add("Make Lower Case", "textformat.size.smaller") { replace(selection.lowercased(), in: view) }
                add("Capitalize", "textformat") { replace(selection.capitalized, in: view) }
                flush()
            }
        } else if hasSelection {
            add("Copy", "doc.on.doc", keys: ["⌘", "C"]) { c.edit("copy") }
            add("Share…", "square.and.arrow.up") { share([selection], c, in: view) }
            flush()
        }
        if hasSelection {
            if voice.isSpeaking {
                add("Stop Speaking", "speaker.slash") { voice.stopSpeaking(at: .immediate) }
            } else {
                add("Speak", "speaker.wave.2") { voice.speak(AVSpeechUtterance(string: selection)) }
            }
            flush()
        }

        // Nothing in particular: the page (or the frame) itself.
        if link == nil, c.mediaKind == .none || c.mediaKind == .canvas, !hasSelection, !c.editable {
            if view.canGoBack { add("Back", "chevron.backward", keys: ["⌘", "["]) { view.goBack() } }
            if view.canGoForward { add("Forward", "chevron.forward", keys: ["⌘", "]"]) { view.goForward() } }
            add("Reload Page", "arrow.clockwise", keys: ["⌘", "R"]) { view.reload() }
            flush()
            if c.inFrame, let frame = c.frameURL, web(frame) {
                add("Reload Frame", "arrow.clockwise") { c.reloadFrame() }
                add("Open Frame in New Tab", "plus.square.on.square") { open(frame, from: tab, background: false) }
                add("Show Frame Source", "chevron.left.forwardslash.chevron.right") { showSource(frame, from: tab) }
                flush()
            }
            if let page = view.url, web(page) {
                add("Save Page As…", "square.and.arrow.down") { saveAs(page, from: tab, in: view) }
                add("Print Page…", "printer", keys: ["⌘", "P"]) { view.print() }
                add("Show Page Source", "chevron.left.forwardslash.chevron.right") { showSource(page, from: tab) }
                flush()
            }
        }

        add("Inspect Element", "hammer", keys: ["⌥", "⌘", "I"]) { c.inspect() }
        flush()
        return entries
    }

    // MARK: - What the items do

    private static func open(_ url: URL, from tab: Tab, background: Bool) {
        _ = tab.host?.open(from: tab, url: url, configuration: nil, background: background)
    }

    private static func openWindow(_ url: URL, isPrivate: Bool) {
        let browser = AppDelegate.shared.makeBrowser(isPrivate: isPrivate)
        browser.addTab(url: url)
        browser.showWindow(nil)
    }

    private static func showSource(_ url: URL, from tab: Tab) {
        guard let source = URL(string: "view-source:" + url.absoluteString) else { return }
        open(source, from: tab, background: false)
    }

    private static func copy(text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Asks where first (named from the address), then Chromium downloads
    /// it there, into the Downloads list.
    private static func saveAs(_ url: URL, from tab: Tab, in view: SillWebView) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if name.isEmpty || name == "/" { name = url.host() ?? "Download" }
        if url == view.url, url.pathExtension.isEmpty || url.pathExtension == "html" {
            let title = tab.displayTitle.isEmpty ? name : tab.displayTitle
            name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".html"
        }
        if url.scheme == "data" { name = "Image" }
        panel.nameFieldStringValue = name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let file = panel.url else { return }
            tab.saveAs[url.absoluteString] = file
            view.startDownload(url)
        }
    }

    private static func copyImage(_ url: URL, _ c: SEContextMenu) {
        func put(_ data: Data?) {
            guard let data, let image = NSImage(data: data) else { return NSSound.beep() }
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects([image])
        }
        if url.scheme == "data" {
            // data:[type][;base64],payload
            let text = url.absoluteString
            guard let comma = text.firstIndex(of: ",") else { return NSSound.beep() }
            let head = text[..<comma], body = String(text[text.index(after: comma)...])
            let payload = body.removingPercentEncoding ?? body
            return put(head.hasSuffix(";base64") ? Data(base64Encoded: payload) : payload.data(using: .utf8))
        }
        c.fetch(url) { data, _ in put(data) }
    }

    /// A script on the video or sound clicked, found by its address in its frame.
    private static func media(_ c: SEContextMenu, _ source: URL, _ action: String) {
        let src = (try? JSONSerialization.data(withJSONObject: [source.absoluteString]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        c.runScript("""
        (() => {
          const src = \(src)[0], all = [];
          const walk = (root) => {
            for (const m of root.querySelectorAll('video, audio')) all.push(m);
            for (const e of root.querySelectorAll('*')) if (e.shadowRoot) walk(e.shadowRoot);
          };
          walk(document);
          const m = all.find(m => m.currentSrc === src || m.src === src) || (all.length === 1 ? all[0] : null);
          if (m) { \(action); }
        })()
        """)
    }

    private static func lookUp(_ text: String, _ c: SEContextMenu, in view: SillWebView) {
        let target = view.contentView ?? view
        let point = target.convert(c.point, from: nil)
        target.showDefinition(for: NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)]),
                              at: point)
    }

    private static func translate(_ text: String, _ c: SEContextMenu, in view: SillWebView) {
        guard let content = view.window?.contentView else { return }
        let point = content.convert(c.point, from: nil)
        var anchor: NSView?
        let host = NSHostingView(rootView: TranslateAnchor(text: text) { anchor?.removeFromSuperview(); anchor = nil })
        host.frame = NSRect(x: point.x, y: point.y, width: 1, height: 1)
        host.safeAreaRegions = []
        content.addSubview(host)
        anchor = host
    }

    /// The system's share sheet, from where the click was.
    private static func share(_ items: [Any], _ c: SEContextMenu, in view: SillWebView) {
        let target = view.contentView ?? view
        let point = target.convert(c.point, from: nil)
        NSSharingServicePicker(items: items).show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1),
                                                  of: target, preferredEdge: .minY)
    }

    /// A key chord into the page, as if typed: kept from Sill's own menus,
    /// as an agent's keys are.
    private static func press(_ key: String, in view: SillWebView) {
        let code = Int(key.uppercased().unicodeScalars.first!.value)
        view.agentKeysUntil = Date.timeIntervalSinceReferenceDate + 0.5
        view.focusPage()
        for type in ["rawKeyDown", "keyUp"] {
            view.devtools("Input.dispatchKeyEvent", params: [
                "type": type, "modifiers": 4, "key": key, "code": "Key" + key.uppercased(),
                "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code,
            ]) { _, _ in }
        }
    }

    private static func replace(_ text: String, in view: SillWebView) {
        view.focusPage()
        view.devtools("Input.insertText", params: ["text": text]) { _, _ in }
    }

    private static let voice = AVSpeechSynthesizer()

    // MARK: - Test copies: the menu as text

    /// With SILL_MENU_DUMP set (test copies only), each menu is written out
    /// instead of shown, so its items can be checked without a click; set
    /// to "show", an agent's right-click shows it, to be looked at.
    enum Dump {
        static let path = ProcessInfo.processInfo.environment["SILL_MENU_DUMP"]
        static func write(_ entries: [GlassMenu.Entry], to path: String) {
            let lines = entries.map { entry -> String in
                switch entry {
                case .separator: return "—"
                case .item(let item):
                    let missing = item.symbol.map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil } ?? false
                    return item.title + (item.isOn ? " ✓" : "") + (item.keys.isEmpty ? "" : "  " + item.keys.joined())
                        + (missing ? "  [no symbol \(item.symbol!)]" : "")
                }
            }
            let text = lines.joined(separator: "\n") + "\n===\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile(); handle.write(Data(text.utf8)); handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
            }
        }
    }
}

/// An invisible spot for the system's Translate popover to point from.
private struct TranslateAnchor: View {
    let text: String
    let done: () -> Void
    @State private var shown = false
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationPresentation(isPresented: $shown, text: text)
            .onAppear { shown = true }
            .onChange(of: shown) { _, now in if !now { done() } }
    }
}
