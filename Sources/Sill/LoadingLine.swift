import AppKit

/// A hairline in the accent colour along the bottom of the bar while the page
/// in front loads.
///
/// WebKit's estimate comes in a few big steps (a tenth, a third, nine
/// tenths), so the line never just runs to each and stops: it glides to the
/// newest figure from wherever it is, then keeps creeping on, slower and
/// slower, toward a little further, so it's always moving and never
/// arrives early. When the page is in it sweeps to the end and fades as it
/// gets there. Nothing shows for a page that's already loaded.
final class LoadingLine: NSView {
    static let thickness: CGFloat = 2
    private let bar = CALayer()
    private var shown = false
    /// The furthest figure WebKit has given for this load.
    private var reached: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bar)
        bar.anchorPoint = .zero
        bar.position = .zero
        bar.cornerRadius = Self.thickness / 2
        bar.actions = ["bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    private func recolor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        }
    }

    override func layout() {
        super.layout()
        // A window resize keeps the line's share of the width.
        guard shown else { return }
        glide(to: reached, quick: true)
    }

    /// The width the line is drawn at this moment, mid-animation or not.
    private var drawnWidth: CGFloat {
        (bar.presentation() ?? bar).bounds.width
    }

    private func setWidth(_ width: CGFloat) {
        bar.bounds = CGRect(x: 0, y: 0, width: width, height: Self.thickness)
    }

    /// From where the line is now to `fraction` of the way, eased out, then
    /// on toward a little further over several seconds, slowing all the way.
    private func glide(to fraction: CGFloat, quick: Bool = false) {
        let width = bounds.width
        guard width > 0 else { return }
        let from = drawnWidth
        let target = max(from, fraction * width)
        let creep = max(target, min(fraction + (0.94 - fraction) * 0.45, 0.94) * width)
        stopGrowing()
        setWidth(creep)
        guard !Motion.reduced else { setWidth(target); return }
        let arrive: CFTimeInterval = quick ? 0.15 : 0.45
        let now = bar.convertTime(CACurrentMediaTime(), from: nil)
        let arrival = CABasicAnimation(keyPath: "bounds.size.width")
        arrival.fromValue = from
        arrival.toValue = target
        arrival.beginTime = now
        arrival.duration = arrive
        arrival.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)   // a soft arrival
        // Held at its end until the creep, added after it and so on top, takes over.
        arrival.fillMode = .forwards
        arrival.isRemovedOnCompletion = false
        bar.add(arrival, forKey: "grow")
        // And a creep that tires: a few points a second for nine seconds, and
        // often the only thing moving while a slow site keeps you waiting. At
        // 30 frames a second rather than the display's 60 or 120: it moves a
        // point or so a frame either way, and the window server composites
        // the window half as often (or a quarter) while it waits.
        let tiring = CABasicAnimation(keyPath: "bounds.size.width")
        tiring.fromValue = target
        tiring.toValue = creep
        tiring.beginTime = now + arrive
        tiring.duration = 9
        tiring.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.5, 0.3, 1)
        tiring.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        // Held at its end too: taken off when done, the arrival still held
        // under it showed through, and the line fell back to where it had
        // arrived (a load stalled for nine seconds; seen in a probe).
        tiring.fillMode = .forwards
        tiring.isRemovedOnCompletion = false
        bar.add(tiring, forKey: "creep")
    }

    private func stopGrowing() {
        bar.removeAnimation(forKey: "grow")
        bar.removeAnimation(forKey: "creep")
    }

    /// `jump`: another tab came to the front; its line starts where its
    /// load is, without growing to it.
    func show(progress: Double, loading: Bool, jump: Bool = false) {
        let fraction = CGFloat(max(0.06, min(progress, 1)))
        if loading {
            if !shown || jump {
                // A new load (or another tab's): from its start, or where that tab is.
                shown = true
                reached = jump ? fraction : 0
                recolor()
                bar.removeAllAnimations()
                layer?.removeAllAnimations()
                setWidth(jump ? fraction * bounds.width : 0)
                isHidden = false
                alphaValue = 1
                if jump { return glide(to: reached, quick: true) }
            }
            guard fraction > reached || reached == 0 else { return }
            reached = max(reached, fraction)
            glide(to: reached)
        } else {
            guard shown else { return }
            shown = false
            reached = 0
            if jump || Motion.reduced {
                bar.removeAllAnimations()
                isHidden = true
                alphaValue = 0
                setWidth(0)
                return
            }
            // To the end, and fading as it gets there.
            let from = drawnWidth
            stopGrowing()
            setWidth(bounds.width)
            let sweep = CABasicAnimation(keyPath: "bounds.size.width")
            sweep.fromValue = from
            sweep.toValue = bounds.width
            sweep.duration = 0.3
            sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
            bar.add(sweep, forKey: "grow")
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
                // Fades a little longer than it sweeps, so the end is seen.
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.shown else { return }
                self.isHidden = true
                self.setWidth(0)
            })
        }
    }
}
