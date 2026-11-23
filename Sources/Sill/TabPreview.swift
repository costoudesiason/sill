import AppKit
import WebKit

/// What a tab holds, shown when the pointer rests on it: a small glass card
/// under the tab with a picture of its page, its title and its site.
///
/// The picture is the page as it was last seen (taken as you leave a tab),
/// replaced by a live one while the card is up if the page is running. Once
/// a card is showing, moving along the row moves it from tab to tab at once;
/// leaving the row puts it away. Never for the tab in front.
final class TabPreview: NSView {
    static let width: CGFloat = 288
    private static let inset: CGFloat = 8

    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private let picture = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let addressLabel = NSTextField(labelWithString: "")
    private(set) weak var tab: Tab?
    private var aspect: CGFloat = 0.6

    override var isFlipped: Bool { true }
    /// A card to look at: clicks go through to the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        alphaValue = 0
        glass.cornerRadius = 18
        glass.contentView = content
        addSubview(glass)

        picture.wantsLayer = true
        picture.layer?.cornerRadius = 11
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.layer?.contentsGravity = .resizeAspectFill
        content.addSubview(picture)

        icon.imageScaling = .scaleProportionallyUpOrDown
        picture.addSubview(icon)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        content.addSubview(titleLabel)

        addressLabel.font = .systemFont(ofSize: 11.5)
        addressLabel.textColor = .secondaryLabelColor
        addressLabel.lineBreakMode = .byTruncatingMiddle
        addressLabel.maximumNumberOfLines = 1
        content.addSubview(addressLabel)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Up, or coming up: a card going away is not, even mid-fade.
    private(set) var isUp = false
    var isShowing: Bool { isUp && tab != nil }

    /// Fills the card for `tab`; `pageSize` gives the picture its shape.
    func fill(_ tab: Tab, pageSize: NSSize) {
        self.tab = tab
        if pageSize.width > 0 { aspect = min(0.8, max(0.45, pageSize.height / pageSize.width)) }
        titleLabel.stringValue = tab.displayTitle
        addressLabel.stringValue = tab.url.map { Domains.bare($0.host()).isEmpty ? Address.display($0) : Domains.bare($0.host()) } ?? ""
        icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = tab.favicon == nil ? .secondaryLabelColor : nil
        show(tab.previewPicture)
        needsLayout = true
    }

    /// The tab's title and site as they are now.
    func retitle() {
        guard let tab else { return }
        titleLabel.stringValue = tab.displayTitle
    }

    /// A newer picture of the page shown.
    func show(_ image: CGImage?) {
        Motion.still {
            if let image {
                picture.layer?.contents = image
                icon.isHidden = true
                picture.layer?.backgroundColor = nil
            } else {
                picture.layer?.contents = nil
                icon.isHidden = false
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    picture.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
                }
            }
        }
    }

    var cardSize: NSSize {
        let inner = Self.width - Self.inset * 2
        return NSSize(width: Self.width, height: Self.inset + round(inner * aspect) + 8 + 17 + 1 + 15 + 10)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let inner = bounds.width - Self.inset * 2
        let pictureHeight = round(inner * aspect)
        picture.frame = NSRect(x: Self.inset, y: Self.inset, width: inner, height: pictureHeight)
        icon.frame = NSRect(x: (inner - 32) / 2, y: (pictureHeight - 32) / 2, width: 32, height: 32)
        let textX = Self.inset + 4, textWidth = inner - 8
        titleLabel.frame = NSRect(x: textX, y: picture.frame.maxY + 8, width: textWidth, height: 17)
        addressLabel.frame = NSRect(x: textX, y: titleLabel.frame.maxY + 1, width: textWidth, height: 15)
    }

    /// Comes in where it's put, or slides there if it's already up.
    /// Only a card already up for another tab slides to the new one; a
    /// card coming up appears in place, fading in (from wherever a fade out
    /// had got to), so nothing travels in from where it last was.
    func present(at origin: NSPoint) {
        let target = NSRect(origin: origin, size: cardSize)
        if isUp {
            if frame.size != target.size { Motion.still { setFrameSize(target.size) }; layoutSubtreeIfNeeded() }
            if frame.origin != target.origin { Motion.animate(0.2) { animator().setFrameOrigin(target.origin) } }
            return
        }
        isUp = true
        Motion.still {
            // Hidden, or fading out somewhere else: from clear, where it belongs.
            if isHidden || frame.origin != target.origin { alphaValue = 0 }
            frame = target
            layer?.removeAllAnimations()
        }
        isHidden = false
        layoutSubtreeIfNeeded()
        Motion.animate(0.16) { animator().alphaValue = 1 }
    }

    func dismiss(animated: Bool = true) {
        guard isUp || !isHidden else { return }
        isUp = false
        tab = nil
        guard animated, !isHidden else {
            Motion.still { alphaValue = 0 }
            isHidden = true
            picture.layer?.contents = nil
            return
        }
        Motion.animate(0.12, { animator().alphaValue = 0 }) { [weak self] in
            guard let self, !self.isUp else { return }
            self.isHidden = true
            Motion.still { self.picture.layer?.contents = nil }
        }
    }
}

extension Tab {
    /// Takes a picture of the page as it is now, for the tab's preview card;
    /// `done` gets it, or nil when the page can't be drawn. Small (the card's
    /// width), and from what's already drawn, without waiting for a frame.
    func capturePicture(_ done: ((CGImage?) -> Void)? = nil) {
        guard let view = webView, view.bounds.width > 0 else { done?(nil); return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(TabPreview.width))
        configuration.afterScreenUpdates = false
        view.takeSnapshot(with: configuration) { [weak self] image, _ in
            let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            if let self, let cg {
                self.picture = cg
                self.pictureTakenAt = CACurrentMediaTime()
            }
            done?(cg)
        }
    }

    /// The picture the card shows now: the running page's, or the one kept
    /// from before it slept, unpacked only when wanted.
    var previewPicture: CGImage? {
        if let picture { return picture }
        guard let data = sleepingPicture, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Squeezes the picture into a small JPEG (tens of kilobytes rather than
    /// most of a megabyte), off the main thread, for as long as the tab sleeps.
    func keepWhileAsleep(_ image: CGImage) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return }
            let packed = data as Data
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sleepingPicture = packed } }
        }
    }
}
