import AppKit
import WebKit

// MARK: - Find

/// ⌘F: a small glass bar under the toolbar's right end, with the system's
/// own search field and arrow buttons.
@MainActor
final class FindBar: NSObject, NSSearchFieldDelegate {
    private weak var browser: BrowserWindowController?
    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private let field = NSSearchField()
    private let result = NSTextField(labelWithString: "")
    private let arrows = NSSegmentedControl()
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private(set) var isOpen = false
    private var raised = false
    var hasQuery: Bool { !field.stringValue.isEmpty }

    private static let size = NSSize(width: 400, height: 44)

    init(browser: BrowserWindowController) {
        self.browser = browser
        super.init()
        glass.cornerRadius = 22
        glass.contentView = content
        glass.isHidden = true
        glass.wantsLayer = true

        field.placeholderString = "Find on Page"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(search)
        field.controlSize = .regular
        content.addSubview(field)

        result.font = .systemFont(ofSize: 11)
        result.textColor = .secondaryLabelColor
        result.alignment = .right
        content.addSubview(result)

        arrows.segmentCount = 2
        arrows.trackingMode = .momentary
        arrows.setImage(NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous"), forSegment: 0)
        arrows.setImage(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next"), forSegment: 1)
        arrows.setWidth(28, forSegment: 0)
        arrows.setWidth(28, forSegment: 1)
        arrows.target = self
        arrows.action = #selector(stepped)
        content.addSubview(arrows)

        done.bezelStyle = .glass
        done.target = self
        done.action = #selector(closeClicked)
        content.addSubview(done)
    }

    func place(in stage: NSView, top: CGFloat) {
        let size = Self.size
        glass.frame = NSRect(x: stage.bounds.width - size.width - 14, y: top + 10, width: size.width, height: size.height)
        content.frame = glass.bounds
        let h = size.height
        done.sizeToFit()
        done.frame.origin = NSPoint(x: size.width - done.frame.width - 8, y: (h - done.frame.height) / 2)
        arrows.sizeToFit()
        arrows.frame.origin = NSPoint(x: done.frame.minX - arrows.frame.width - 8, y: (h - arrows.frame.height) / 2)
        result.frame = NSRect(x: arrows.frame.minX - 78, y: (h - 14) / 2, width: 70, height: 14)
        field.frame = NSRect(x: 10, y: (h - 24) / 2, width: result.frame.minX - 14, height: 24)
    }

    /// Puts the bar in the window, hidden and laid out, ahead of its first use.
    func ready(in stage: NSView, top: CGFloat) {
        guard glass.superview == nil else { return }
        stage.addSubview(glass)
        place(in: stage, top: top)
        glass.layoutSubtreeIfNeeded()
    }

    func open(in stage: NSView, top: CGFloat) {
        // Above whatever came after it was readied, as when it was made here.
        if glass.superview !== stage || (!raised && stage.subviews.last !== glass) { stage.addSubview(glass) }
        raised = true
        place(in: stage, top: top)
        stage.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        guard !isOpen else { return }
        isOpen = true
        glass.isHidden = false
        glass.alphaValue = 0
        Motion.animate(Motion.quick) { glass.animator().alphaValue = 1 }
        if hasQuery { search() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        Motion.animate(Motion.quick, { glass.animator().alphaValue = 0 }, completion: { [weak self] in
            guard let self, !self.isOpen else { return }
            self.glass.isHidden = true
        })
        if let webView = browser?.selected?.webView { webView.window?.makeFirstResponder(webView) }
    }

    @objc private func closeClicked() { close() }
    /// Typing searches for what is in the field once the search before it
    /// has answered, not once per key: on a very long page each one walks
    /// the whole document, and a word typed quickly queued a dozen of them.
    @objc private func search() {
        // A search that never answers (its page crashed) must not hold the next one back for good.
        if let searching, searching === browser?.selected?.webView, CACurrentMediaTime() - began < 5 {
            stale = true
        } else {
            find(backwards: false)
        }
    }

    private weak var searching: WKWebView?
    private var stale = false
    private var began: CFTimeInterval = 0
    @objc private func stepped() { find(backwards: arrows.selectedSegment == 0) }

    func find(backwards: Bool) {
        guard let webView = browser?.selected?.webView, hasQuery else {
            result.stringValue = ""
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        searching = webView
        stale = false
        began = CACurrentMediaTime()
        webView.find(field.stringValue, configuration: configuration) { [weak self, weak webView] found in
            guard let self else { return }
            if self.searching === webView { self.searching = nil }
            if self.stale, self.browser?.selected?.webView === webView {
                self.find(backwards: false)
            } else {
                self.result.stringValue = found.matchFound ? "" : "Not found"
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            find(backwards: NSEvent.modifierFlags.contains(.shift))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

// MARK: - Status

/// The address of the link under the pointer, bottom left, as plain content
/// (a material, not glass: it isn't something you press).
final class StatusPill: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hiding: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .toolTip
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        alphaValue = 0
        // Hidden when faded out, not just clear: its blur sits over the page
        // and samples it, and a scrolling page would have it redone.
        isHidden = true
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String?) {
        hiding?.cancel()
        if let text, !text.isEmpty {
            label.stringValue = text
            superview.map(place)
            isHidden = false
            if alphaValue < 1 { Motion.animate(0.1) { animator().alphaValue = 1 } }
        } else {
            guard !isHidden else { return }
            let work = DispatchWorkItem { [weak self] in
                Motion.animate(0.12, { self?.animator().alphaValue = 0 }, completion: {
                    // Unless a link came under the pointer meanwhile.
                    if let self, self.alphaValue == 0 { self.isHidden = true }
                })
            }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    func place(in stage: NSView) {
        label.sizeToFit()
        let width = min(stage.bounds.width * 0.6, label.frame.width + 16)
        frame = NSRect(x: 12, y: stage.bounds.height - 12 - 22, width: width, height: 22)
        label.frame = NSRect(x: 8, y: (22 - label.frame.height) / 2, width: width - 16, height: label.frame.height)
    }
}

// MARK: - Toast

/// A short note at the bottom of the window (a download landed, a link was
/// copied), with at most one action. Glass, since it can hold a button.
final class Toast: NSView {
    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    private var hiding: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        glass.cornerRadius = 20
        glass.contentView = content
        addSubview(glass)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        content.addSubview(label)
        button.bezelStyle = .glass
        button.controlSize = .small
        button.target = self
        button.action = #selector(run)
        content.addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A burst of them (twenty downloads starting, or ending, together) is
    /// laid out and drawn twenty times a second at most, ending on the last:
    /// each one measures its text and button, and only the last is read.
    func show(_ text: String, action: (String, () -> Void)?, in stage: NSView) {
        if CACurrentMediaTime() - shownAt < 0.05 {
            let scheduled = waiting != nil
            waiting = (text, action, stage)
            if !scheduled {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, let (text, action, stage) = self.waiting else { return }
                    self.waiting = nil
                    self.present(text, action: action, in: stage)
                }
            }
            return
        }
        waiting = nil
        present(text, action: action, in: stage)
    }

    private var shownAt: CFTimeInterval = 0
    private var waiting: (String, (String, () -> Void)?, NSView)?

    private func present(_ text: String, action: (String, () -> Void)?, in stage: NSView) {
        shownAt = CACurrentMediaTime()
        hiding?.cancel()
        label.stringValue = text
        self.action = action?.1
        button.isHidden = action == nil
        button.title = action?.0 ?? ""
        place(in: stage)
        if isHidden || alphaValue < 1 {
            isHidden = false
            alphaValue = 0
            Motion.animate(0.2) { animator().alphaValue = 1 }
        }
        let work = DispatchWorkItem { [weak self] in
            Motion.animate(0.18, { self?.animator().alphaValue = 0 }, completion: { self?.isHidden = true })
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 2.2 : 5), execute: work)
    }

    func place(in stage: NSView) {
        label.sizeToFit()
        button.sizeToFit()
        let labelWidth = min(label.frame.width, 360)
        let width = 18 + labelWidth + (button.isHidden ? 18 : 10 + button.frame.width + 8)
        let height: CGFloat = 40
        frame = NSRect(x: (stage.bounds.width - width) / 2, y: stage.bounds.height - height - 18, width: width, height: height)
        glass.frame = bounds
        content.frame = glass.bounds
        label.frame = NSRect(x: 18, y: (height - label.frame.height) / 2, width: labelWidth, height: label.frame.height)
        button.frame.origin = NSPoint(x: label.frame.maxX + 10, y: (height - button.frame.height) / 2)
    }

    @objc private func run() {
        action?()
        hiding?.perform()
    }
}
