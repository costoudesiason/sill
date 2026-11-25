import AppKit
import CoreImage
import IOKit.pwr_mgt
import QuartzCore

// While an agent works in a tab, the tab says so without getting in the way:
// six small dots twinkle beside its icon, and if you bring the tab to the
// front, light moves in waves round the page's edges. The work itself happens
// out of sight (AgentControl): you see tabs open and twinkle, never clicks.

@MainActor
final class AgentActivity {
    static let shared = AgentActivity()

    private struct Work {
        weak var tab: Tab?
        weak var view: SillWebView?
        weak var browser: BrowserWindowController?
        var last: Date
        var dots: TwinkleDots?
        weak var tabView: TabItemView?
        var glow: AgentEdgeGlow?
        var owner: ObjectIdentifier?   // the agent's connection, when it came over the socket
    }

    private var work: [ObjectIdentifier: Work] = [:]
    private var latest: ObjectIdentifier?
    private var busy = 0
    private var timer: Timer?

    /// A tab is the agent's from its first touch until it's released: closed,
    /// handed back (tabs_release), the agent gone (its connection closed), or
    /// left untouched this long. All that time, its dots and glow show. A chat
    /// you stop in claude.ai says nothing to Sill (the relay's line stays up),
    /// so a minute without a touch is taken as the agent having stopped: long
    /// enough for a model's longest pause between steps, and it takes the tab
    /// up again with its next one.
    private let release: TimeInterval = 60

    func began() { busy += 1; keepAwake() }
    func ended() {
        busy = max(0, busy - 1)
        if let latest { work[latest]?.last = Date() }   // the fade counts from when the work ended
        keepAwake()
    }

    /// The agent was stopped (its client cancelled a call): every tab goes dark now.
    /// They stay its own; the next command lights them again.
    func quiet() { for key in Array(work.keys) { work[key]?.last = .distantPast; hide(key) } }

    // MARK: awake while working

    private var assertion: IOPMAssertionID = 0
    private var letSleep: DispatchWorkItem?

    /// While an agent is at work the Mac doesn't doze off for being left
    /// alone (as a download or a video call keeps it up); two minutes after
    /// the last command it may again. A closed lid still sleeps it: macOS
    /// decides that, and no app can.
    private func keepAwake() {
        if assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "An agent is working in Sill" as CFString, &assertion)
        }
        letSleep?.cancel()
        let release = DispatchWorkItem { [weak self] in
            guard let self, self.busy == 0, self.assertion != 0 else { return }
            IOPMAssertionRelease(self.assertion)
            self.assertion = 0
        }
        letSleep = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: release)
    }

    func touch(_ tab: Tab, view: SillWebView, in browser: BrowserWindowController) {
        let key = ObjectIdentifier(tab)
        var item = work[key] ?? Work(tab: tab, view: view, browser: browser, last: Date())
        item.view = view
        item.browser = browser
        item.last = Date()
        if let owner = AgentCommands.owner { item.owner = owner }
        work[key] = item
        latest = key
        show(key)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                MainActor.assumeIsolated { AgentActivity.shared.tick() }
            }
        }
    }

    /// The agent touched this tab a moment ago, or is mid-command in it.
    func isWorking(on tab: Tab) -> Bool {
        let key = ObjectIdentifier(tab)
        guard let item = work[key] else { return false }
        return Date().timeIntervalSince(item.last) < 3 || (busy > 0 && key == latest)
    }

    func forget(_ tab: Tab) {
        let key = ObjectIdentifier(tab)
        hide(key, now: true)
        work[key] = nil
    }

    /// The agent has handed the tab back (or the tab's being closed): its dots and glow fade, and its page is put aside.
    func release(_ tab: Tab) {
        let key = ObjectIdentifier(tab)
        guard let item = work[key] else { return }
        if let view = item.view { AgentCommands.letGo(view, of: tab) }
        hide(key)
        work[key] = nil
    }

    /// Everything one agent held, when it goes away (its connection closed).
    func releaseAll(owner: ObjectIdentifier) {
        for (_, item) in work where item.owner == owner { if let tab = item.tab { release(tab) } }
    }

    /// Tabs the agent holds now.
    var held: [Tab] { work.values.compactMap(\.tab) }

    private func tick() {
        for (key, item) in work {
            guard let tab = item.tab else { hide(key, now: true); work[key] = nil; continue }
            let current = busy > 0 && key == latest
            // Dots and glow only while the agent is at work in the tab: acting in it
            // now, or a few seconds after (a model choosing its next step). Nothing
            // tells Sill a chat was paused or stopped, so the glow follows the work
            // itself: no more commands, and it fades. The tab stays the agent's
            // (its next command lights it again) until released.
            if current || Date().timeIntervalSince(item.last) < 5 { show(key) } else { hide(key) }
            if Date().timeIntervalSince(item.last) > release && !current {
                if let view = item.view { AgentCommands.letGo(view, of: tab) }
                hide(key, now: true)
                work[key] = nil
                // Left behind, never shown to you nor handed over: tidied, so the agent needn't spend a turn closing it.
                AgentCommands.tidy(tab)
            }
        }
        if work.isEmpty { timer?.invalidate(); timer = nil }
    }

    private func show(_ key: ObjectIdentifier) {
        guard var item = work[key], let tab = item.tab, let browser = item.browser else { return }
        // The dots: on the tab's view in the strip, which the strip may have made anew.
        let known = item.tabView.flatMap { $0.window != nil && $0.tab === tab && !$0.isLeaving ? $0 : nil }
        if let tabView = known ?? Self.tabItemView(of: tab, in: browser) {
            let dots = item.dots ?? TwinkleDots()
            item.dots = dots
            if tabView.agentDots !== dots {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.allowsImplicitAnimation = true
                    tabView.agentDots = dots
                    tabView.layoutSubtreeIfNeeded()
                }
            }
            item.tabView = tabView
            dots.start()
        }
        // The glow: only on a page you're looking at.
        let inFront = browser.selected === tab || browser.split?.contains(tab) == true
        if let view = item.view, view.isShown, inFront {
            if item.glow?.superview !== view { item.glow?.removeFromSuperview(); item.glow = AgentEdgeGlow(in: view) }
            item.glow?.show()
        } else {
            item.glow?.hide()
        }
        work[key] = item
    }

    private func hide(_ key: ObjectIdentifier, now: Bool = false) {
        guard var item = work[key] else { return }
        item.glow?.hide()
        if let tabView = item.tabView, tabView.agentDots != nil {
            item.dots?.stop()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = now ? 0 : 0.3
                context.allowsImplicitAnimation = true
                tabView.agentDots = nil
                tabView.layoutSubtreeIfNeeded()
            }
        }
        if now { item.glow?.removeFromSuperview(); item.glow = nil }
        work[key] = item
    }

    private static func tabItemView(of tab: Tab, in browser: BrowserWindowController) -> TabItemView? {
        func search(_ view: NSView) -> TabItemView? {
            if let item = view as? TabItemView, item.tab === tab, !item.isLeaving { return item }
            for child in view.subviews { if let found = search(child) { return found } }
            return nil
        }
        guard let root = browser.window?.contentView?.superview ?? browser.window?.contentView else { return nil }
        return search(root)
    }
}

// MARK: - The dots

/// Six dots in a braille cell, two or three lit at a time, changing at
/// random: something's thinking. In the label colour, so it sits in the tab
/// like its text.
final class TwinkleDots: NSView {
    private var dots: [CALayer] = []
    private var timer: Timer?
    private var lit: Set<Int> = []
    private static let size: CGFloat = 2.6
    private static let pitch: CGFloat = 4.6

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 8, height: 12))
        wantsLayer = true
        for _ in 0..<6 {
            let dot = CALayer()
            dot.cornerRadius = Self.size / 2
            dot.opacity = 0.2
            layer?.addSublayer(dot)
            dots.append(dot)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.labelColor.cgColor
            for dot in dots { dot.backgroundColor = color }
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = Self.size + Self.pitch, height = Self.size + Self.pitch * 2
        let origin = CGPoint(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2)
        for (i, dot) in dots.enumerated() {
            // Braille order: down the left column, then the right; top first.
            let column = CGFloat(i / 3), row = CGFloat(i % 3)
            dot.frame = CGRect(x: origin.x + column * Self.pitch, y: origin.y + (2 - row) * Self.pitch,
                               width: Self.size, height: Self.size)
        }
        CATransaction.commit()
    }

    func start() {
        guard timer == nil else { return }
        needsDisplay = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            light([0, 2, 4])   // still: a fixed pattern says the same
            return
        }
        step()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        // Two or three dots, never the same set twice running.
        var next: Set<Int>
        repeat {
            next = Set((0..<6).shuffled().prefix(Int.random(in: 2...3)))
        } while next == lit
        light(next)
    }

    private func light(_ next: Set<Int>) {
        let first = lit.isEmpty
        for (i, dot) in dots.enumerated() {
            let on = next.contains(i)
            guard first || on != lit.contains(i) else { continue }
            CATransaction.begin()
            // Quick to light, slower to fade: a twinkle, not a blink.
            CATransaction.setAnimationDuration(on ? 0.12 : 0.24)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: on ? .easeOut : .easeIn))
            dot.opacity = on ? 0.9 : 0.2
            CATransaction.commit()
        }
        lit = next
    }
}

// MARK: - The glow

/// Light round the edges of the page while an agent works in it: two soft
/// bands of the shimmer's colours, turning slowly in opposite directions at
/// different speeds. Where they meet the edge brightens, elsewhere it fades
/// away, so the light travels round in waves and never rims the whole page.
/// The soft edge is drawn once for the page's size; only the two turns and a
/// slow breath are animated, so it costs the compositor next to nothing.
final class AgentEdgeGlow: NSView {
    private let holder = CALayer()            // masked by the soft edge, still
    private let edge = CALayer()
    private let bands = [CAGradientLayer(), CAGradientLayer()]
    private var maskedFor: CGSize = .zero
    private var shown = false
    private var redraw: DispatchWorkItem?

    /// How far the light reaches in from the edge at its brightest.
    private let depth: CGFloat = 30

    private static func color(_ hex: Int, _ alpha: CGFloat) -> CGColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha).cgColor
    }
    // The shimmer's blue, violet, pink and coral, each band with its own lit
    // stretches and gaps; the gaps are what make it a wave and not a frame.
    private static let first: [CGColor] = [
        color(0x5E8BFF, 0.95), color(0xA45CFF, 0.55), color(0xA45CFF, 0), color(0xFF4F8B, 0),
        color(0xFF4F8B, 0.9), color(0xFF7A65, 0.4), color(0x5E8BFF, 0), color(0x5E8BFF, 0.95),
    ]
    private static let second: [CGColor] = [
        color(0xFF4F8B, 0), color(0xA45CFF, 0.85), color(0x5E8BFF, 0.5), color(0x5E8BFF, 0),
        color(0xFF7A65, 0), color(0xFF7A65, 0.8), color(0xA45CFF, 0.35), color(0xFF4F8B, 0),
    ]

    init(in host: NSView) {
        super.init(frame: host.bounds)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        isHidden = true
        if let layer {
            layer.opacity = 0
            for (band, colors) in zip(bands, [Self.first, Self.second]) {
                band.type = .conic
                band.colors = colors
                band.startPoint = CGPoint(x: 0.5, y: 0.5)
                band.endPoint = CGPoint(x: 0.5, y: 0)
                holder.addSublayer(band)
            }
            bands[1].opacity = 0.8
            holder.mask = edge
            edge.contentsGravity = .resize
            layer.addSublayer(holder)
        }
        host.addSubview(self, positioned: .above, relativeTo: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let b = bounds
        // A conic gradient turns about the centre; a square on the diagonal
        // covers every corner whatever its angle.
        let side = hypot(b.width, b.height)
        holder.frame = b
        edge.frame = b
        for band in bands {
            band.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            band.position = CGPoint(x: b.midX, y: b.midY)
        }
        CATransaction.commit()
        // While a window is being resized the soft edge stretches; it's
        // drawn again for the new size once the resizing pauses.
        if b.size != maskedFor {
            redraw?.cancel()
            let again = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.drawSoftEdge() } }
            redraw = again
            DispatchQueue.main.asyncAfter(deadline: .now() + (maskedFor == .zero ? 0 : 0.12), execute: again)
        }
    }

    /// The edge's falloff: a ring at the border, blurred, at half resolution
    /// (it's all softness: nobody can tell, and it's a quarter the pixels).
    private func drawSoftEdge() {
        let size = bounds.size
        guard size.width > 2, size.height > 2 else { return }
        maskedFor = size
        let scale: CGFloat = 0.5
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setStrokeColor(gray: 1, alpha: 1)
        let line = depth * scale
        context.setLineWidth(line)
        context.stroke(CGRect(x: 0, y: 0, width: w, height: h))
        guard let ring = context.makeImage() else { return }
        let blurred = CIImage(cgImage: ring).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(depth * scale * 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let alpha = blurred.applyingFilter("CIMaskToAlpha")   // a mask reads alpha
        guard let image = CIContext().createCGImage(alpha, from: alpha.extent) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.contents = image
        CATransaction.commit()
    }

    func show() {
        guard let layer, let host = superview else { return }
        // Chromium's own view may have arrived on top since.
        if host.subviews.last !== self { host.addSubview(self, positioned: .above, relativeTo: nil) }
        guard !shown else { return }
        shown = true
        isHidden = false
        needsLayout = true
        animateOpacity(of: layer, to: 1, duration: 0.6, curve: CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Opposite ways, at speeds that don't divide evenly: the meeting
        // points wander, and the pattern takes a long while to repeat.
        for (band, (period, direction)) in zip(bands, [(7.0, -1.0), (11.0, 1.0)]) where band.animation(forKey: "turn") == nil {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = direction * 2 * Double.pi
            turn.duration = period
            turn.repeatCount = .infinity
            band.add(turn, forKey: "turn")
        }
        if holder.animation(forKey: "breathe") == nil {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.7
            breathe.toValue = 1
            breathe.duration = 2.2
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            holder.add(breathe, forKey: "breathe")
        }
    }

    func hide() {
        guard shown, let layer else { return }
        shown = false
        animateOpacity(of: layer, to: 0, duration: 0.7, curve: CAMediaTimingFunction(name: .easeInEaseOut)) { [weak self] in
            guard let self, !self.shown else { return }
            self.bands.forEach { $0.removeAllAnimations() }
            self.holder.removeAllAnimations()
            self.isHidden = true
        }
    }

    private func animateOpacity(of layer: CALayer, to value: Float, duration: CFTimeInterval,
                                curve: CAMediaTimingFunction, then done: (() -> Void)? = nil) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = value
        fade.duration = duration
        fade.timingFunction = curve
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        layer.opacity = value
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

/// An app on the internet asks to drive Sill through the connector (Connector.swift).
@MainActor
enum ConnectorApproval {
    static func ask(host: String) async -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow \(host) to control Sill?"
        alert.informativeText = "It will be able to open tabs, read and act on pages, take screenshots and search your history, in Sill’s normal windows. Never private windows or saved passwords.\n\nAllow only if you just added Sill as a connector there."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        if let window = AppDelegate.shared.current?.window, window.isVisible {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// An agent wants to put files from this Mac into a page.
    static func allowUpload(_ paths: [String], to site: String) async -> Bool {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let title = names.count == 1 ? "Let the agent upload “\(names[0])” to \(site)?" : "Let the agent upload \(names.count) files to \(site)?"
        return await AgentAsk.ask(title: title, detail: paths.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"),
                                  allow: "Upload").allowed
    }
}
