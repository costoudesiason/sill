import AppKit
import SwiftUI

/// The settings' icons, which move when the pointer is on their row.
/// Nothing else in the palette moves.
enum IconKind {
    case search, appearance, corners, reopen, previews, pip, sleep, claude
    case shield, key, link, connected, history, trash, globe, importing
    case terminal, copy, code, permissions
}

/// Built only from Apple's SF Symbols; where an icon has parts, each part is
/// its own symbol, so a moon can settle while its z's drift up. Moves like
/// the icons on Alcove's site: eased over about 0.3 s, parts a few tens of
/// milliseconds apart, held while pointed at and eased back after.
struct HoverIcon: View {
    let kind: IconKind
    var on: Bool
    var size: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        Parts(kind: kind, on: on && !still, s: size)
            .frame(width: size + 3, height: size + 3)
    }
}

/// CSS's `ease`, as the sites use it.
private func ease(_ duration: Double = 0.3, delay: Double = 0) -> Animation {
    .timingCurve(0.25, 0.1, 0.25, 1, duration: duration).delay(delay)
}

private struct Parts: View {
    let kind: IconKind
    let on: Bool
    let s: CGFloat

    private func sf(_ name: String, _ scale: CGFloat = 1, _ weight: Font.Weight = .medium) -> some View {
        Image(systemName: name).font(.system(size: s * scale, weight: weight))
    }

    var body: some View {
        let u = s / 13
        switch kind {
        case .search:
            // Tips back from its handle, as the site's speech bubble does.
            sf("magnifyingglass")
                .rotationEffect(.degrees(on ? -14 : 0), anchor: .bottomTrailing)
                .animation(ease(), value: on)
        case .appearance:
            sf("circle.lefthalf.filled")
                .rotationEffect(.degrees(on ? 180 : 0))
                .animation(ease(0.35), value: on)
        case .corners:
            sf("macwindow")
                .rotationEffect(.degrees(on ? -4 : 0))
                .offset(y: on ? -1 * u : 0)
                .animation(ease(), value: on)
        case .reopen:
            sf("arrow.counterclockwise", 1, .semibold)
                .rotationEffect(.degrees(on ? -50 : 0))
                .animation(ease(0.35), value: on)
        case .previews:
            ZStack {
                sf("rectangle", 0.72, .semibold)
                    .offset(x: (on ? -3.2 : -2) * u, y: (on ? 2.6 : 1.8) * u)
                    .animation(ease(), value: on)
                sf("rectangle.fill", 0.72)
                    .offset(x: (on ? 3.2 : 2) * u, y: (on ? -2.6 : -1.8) * u)
                    .animation(ease(delay: 0.05), value: on)
            }
        case .pip:
            // The small window hops to the other corner.
            ZStack {
                sf("rectangle", 1, .semibold)
                sf("rectangle.fill", 0.42)
                    .offset(x: (on ? -2.6 : 2.6) * u, y: (on ? -1.5 : 1.5) * u)
                    .animation(ease(0.35), value: on)
            }
        case .sleep:
            ZStack {
                sf("moon.fill", 0.82)
                    .rotationEffect(.degrees(on ? -24 : 0))
                    .offset(x: -1.8 * u, y: 1.5 * u)
                    .animation(ease(), value: on)
                sf("zzz", 0.5, .bold)
                    .offset(x: 4.2 * u, y: (on ? -6 : -3.8) * u)
                    .opacity(on ? 1 : 0.75)
                    .animation(ease(delay: 0.06), value: on)
            }
        case .claude:
            ZStack {
                sf("sparkle", 0.86)
                    .rotationEffect(.degrees(on ? 90 : 0))
                    .offset(x: -1 * u, y: 1 * u)
                    .animation(ease(0.4), value: on)
                sf("sparkle", 0.4)
                    .scaleEffect(on ? 1.3 : 0.8)
                    .offset(x: 5 * u, y: -5 * u)
                    .animation(ease(delay: 0.08), value: on)
            }
        case .shield:
            sf("checkmark.shield.fill")
                .rotationEffect(.degrees(on ? -10 : 0), anchor: .bottom)
                .animation(ease(), value: on)
        case .key:
            // Turns in the lock, from its ring.
            sf("key.fill", 0.95)
                .rotationEffect(.degrees(on ? -30 : 0), anchor: UnitPoint(x: 0.3, y: 0.35))
                .animation(ease(0.35), value: on)
        case .link:
            sf("link")
                .rotationEffect(.degrees(on ? -45 : 0))
                .animation(ease(), value: on)
        case .connected:
            sf("checkmark", 0.95, .bold)
                .rotationEffect(.degrees(on ? -10 : 0))
                .animation(ease(), value: on)
        case .history:
            // The hands go round, as the site's clock's do.
            ZStack {
                sf("circle", 1, .semibold)
                Capsule().frame(width: 1.7 * u, height: 4.4 * u).offset(y: -1.9 * u)
                    .rotationEffect(.degrees(on ? 180 : 0))
                    .animation(ease(0.35), value: on)
                Capsule().frame(width: 1.7 * u, height: 3.2 * u).offset(y: -1.3 * u)
                    .rotationEffect(.degrees(on ? 135 : 90))
                    .animation(ease(0.3), value: on)
            }
        case .trash:
            sf("trash.fill", 0.95)
                .rotationEffect(.degrees(on ? -10 : 0), anchor: .bottomLeading)
                .offset(y: on ? -0.6 * u : 0)
                .animation(ease(), value: on)
        case .globe:
            sf("globe")
                .rotation3DEffect(.degrees(on ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .animation(ease(0.45), value: on)
        case .importing:
            // The arrow drops into the tray.
            ZStack {
                sf("tray", 0.95)
                    .offset(y: 1.6 * u)
                sf("arrow.down", 0.55, .bold)
                    .offset(y: (on ? 0.4 : -3.2) * u)
                    .animation(ease(), value: on)
            }
        case .terminal:
            ZStack {
                sf("chevron.right", 0.62, .bold)
                    .offset(x: (on ? -1.5 : -3) * u, y: -1 * u)
                    .animation(ease(), value: on)
                Capsule().frame(width: 4.5 * u, height: 1.7 * u)
                    .offset(x: (on ? 4.2 : 2.8) * u, y: 3.2 * u)
                    .animation(ease(delay: 0.1), value: on)
            }
        case .copy:
            ZStack {
                sf("doc", 0.78, .semibold)
                    .offset(x: (on ? -2.8 : -1.8) * u, y: (on ? -2.2 : -1.4) * u)
                    .animation(ease(), value: on)
                sf("doc.fill", 0.78)
                    .offset(x: (on ? 2.8 : 1.8) * u, y: (on ? 2.2 : 1.4) * u)
                    .animation(ease(delay: 0.05), value: on)
            }
        case .permissions:
            // The hand goes up.
            sf("hand.raised.fill", 0.95)
                .rotationEffect(.degrees(on ? -12 : 0), anchor: .bottom)
                .offset(y: on ? -1.2 * u : 0)
                .animation(ease(), value: on)
        case .code:
            // The brackets open.
            ZStack {
                sf("chevron.left", 0.6, .bold).offset(x: (on ? -4.6 : -3.4) * u)
                sf("chevron.right", 0.6, .bold).offset(x: (on ? 4.6 : 3.4) * u)
                sf("line.diagonal", 0.7, .bold).rotationEffect(.degrees(on ? 12 : 0))
            }
            .animation(ease(), value: on)
        }
    }
}

/// The palette's round Liquid Glass buttons (its settings button and the
/// settings' X): the system's glass button with an SF Symbol, both the same
/// size, still.
final class GlassIconButton: NSButton {
    init(symbol: String, label: String, weight: NSFont.Weight = .regular) {
        super.init(frame: .zero)
        bezelStyle = .glass
        borderShape = .circle
        controlSize = .large
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: weight))
        imagePosition = .imageOnly
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError() }
}
