import AppKit

/// A hairline in the accent colour along the bottom of the bar while the page
/// in front loads: it grows with WebKit's own estimate, runs to the end
/// when the page is in, and fades. Nothing shows for a page already loaded.
final class LoadingLine: NSView {
    static let thickness: CGFloat = 2
    private let bar = CALayer()
    private var shown = false
    private var fraction: CGFloat = 0

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bar)
        bar.anchorPoint = .zero
        bar.cornerRadius = Self.thickness / 2
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
            bar.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        }
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    private func place(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Motion.reduced)
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(Motion.curve)
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: Self.thickness)
        CATransaction.commit()
    }

    /// `jump`: another tab came to the front; its line is put where its
    /// load is, without growing to it.
    func show(progress: Double, loading: Bool, jump: Bool = false) {
        if loading {
            let target = CGFloat(max(0.08, min(progress, 1)))
            if !shown || jump || target < fraction {
                shown = true
                recolor()
                fraction = jump ? target : min(target, 0.08)
                place(animated: false)
                isHidden = false
                alphaValue = 1
                layer?.removeAllAnimations()
            }
            fraction = max(fraction, target)
            place(animated: !jump)
        } else {
            guard shown else { return }
            shown = false
            if jump {
                isHidden = true
                alphaValue = 0
                fraction = 0
                return
            }
            // To the end, then gone.
            fraction = 1
            place(animated: true)
            Motion.animate(0.3, { animator().alphaValue = 0 }, completion: { [weak self] in
                guard let self, !self.shown else { return }
                self.isHidden = true
                self.fraction = 0
            })
        }
    }
}
