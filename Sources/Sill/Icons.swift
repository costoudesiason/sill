import AppKit
import SwiftUI

/// The settings' icons, which move when the pointer is on their row.
/// Nothing else in the palette moves.
enum IconKind {
    case search, appearance, corners, reopen, previews, pip, sleep, claude
    case shield, key, link, connected, history, trash, globe, importing
    case terminal, copy, code, permissions
}

/// Built from Apple's SF Symbols; where an icon has parts, each part is its
/// own symbol. Every motion says what the setting does (a globe turns to
/// other continents, light and dark swap sides, a bin lifts its lid, a key
/// turns), on one smooth curve with no bounce: held while pointed at and
/// eased back after, or, for a turn, played once.
struct HoverIcon: View {
    let kind: IconKind
    var on: Bool
    var size: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var still
    /// Counts the times the pointer came on: what a once-only motion plays to.
    @State private var arrivals = 0

    var body: some View {
        Parts(kind: kind, on: on && !still, arrivals: still ? 0 : arrivals, s: size)
            .frame(width: size + 3, height: size + 3)
            .onChange(of: on) { _, now in if now { arrivals += 1 } }
    }
}

/// One curve for every icon: quick to start, soft to land, no overshoot.
private func glide(_ duration: Double = 0.32, delay: Double = 0) -> Animation {
    .smooth(duration: duration).delay(delay)
}

private struct Parts: View {
    let kind: IconKind
    let on: Bool
    let arrivals: Int
    let s: CGFloat

    private func sf(_ name: String, _ scale: CGFloat = 1, _ weight: Font.Weight = .medium) -> some View {
        Image(systemName: name).font(.system(size: s * scale, weight: weight))
    }

    /// Swaps one symbol for another the way the system does (Magic Replace).
    private func swap(_ rest: String, _ pointed: String, _ scale: CGFloat = 1) -> some View {
        sf(on ? pointed : rest, scale)
            .contentTransition(.symbolEffect(.replace))
            .animation(glide(), value: on)
    }

    var body: some View {
        let u = s / 13
        switch kind {
        case .search:
            // Leans in for a closer look.
            sf("magnifyingglass")
                .scaleEffect(on ? 1.12 : 1)
                .rotationEffect(.degrees(on ? -10 : 0))
                .offset(x: on ? -0.6 * u : 0, y: on ? -0.6 * u : 0)
                .animation(glide(), value: on)
        case .appearance:
            // Light and dark change sides.
            swap("circle.lefthalf.filled", "circle.righthalf.filled")
        case .corners:
            // The corners round off.
            swap("square", "app")
        case .reopen:
            // One full turn back, then still.
            sf("arrow.counterclockwise", 1, .semibold)
                .rotationEffect(.degrees(Double(arrivals) * -360))
                .animation(glide(0.6), value: arrivals)
        case .previews:
            ZStack {
                sf("rectangle", 0.72, .semibold)
                    .offset(x: (on ? -2.8 : -2) * u, y: (on ? 2.4 : 1.8) * u)
                sf("rectangle.fill", 0.72)
                    .offset(x: (on ? 2.8 : 2) * u, y: (on ? -2.4 : -1.8) * u)
            }
            .animation(glide(), value: on)
        case .pip:
            // The small window slides to the other corner.
            ZStack {
                sf("rectangle", 1, .semibold)
                sf("rectangle.fill", 0.42)
                    .offset(x: (on ? -2.6 : 2.6) * u, y: (on ? -1.5 : 1.5) * u)
                    .animation(glide(0.36), value: on)
            }
        case .sleep:
            // The moon settles; the z's rise.
            ZStack {
                sf("moon.fill", 0.82)
                    .rotationEffect(.degrees(on ? -14 : 0))
                    .offset(x: -1.8 * u, y: 1.5 * u)
                    .animation(glide(), value: on)
                sf("zzz", 0.5, .bold)
                    .offset(x: 4.2 * u, y: (on ? -5.6 : -3.8) * u)
                    .opacity(on ? 1 : 0.6)
                    .animation(glide(0.36, delay: 0.04), value: on)
            }
        case .claude:
            ZStack {
                sf("sparkle", 0.86)
                    .rotationEffect(.degrees(on ? 45 : 0))
                    .offset(x: -1 * u, y: 1 * u)
                    .animation(glide(0.4), value: on)
                sf("sparkle", 0.4)
                    .scaleEffect(on ? 1.2 : 0.75)
                    .opacity(on ? 1 : 0.7)
                    .offset(x: 5 * u, y: -5 * u)
                    .animation(glide(delay: 0.06), value: on)
            }
        case .shield:
            // Stands a little taller.
            sf("checkmark.shield.fill")
                .scaleEffect(on ? 1.1 : 1, anchor: .bottom)
                .animation(glide(), value: on)
        case .key:
            // Turns in the lock, about its own length.
            sf("key.horizontal.fill", 0.95)
                .rotation3DEffect(.degrees(on ? 70 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.3)
                .animation(glide(0.36), value: on)
        case .link:
            sf("link")
                .rotationEffect(.degrees(on ? -20 : 0))
                .animation(glide(), value: on)
        case .connected:
            sf("checkmark", 0.95, .bold)
                .symbolEffect(.bounce, value: arrivals)
        case .history:
            // The hands go round once.
            ZStack {
                sf("circle", 1, .semibold)
                Capsule().frame(width: 1.7 * u, height: 4.4 * u).offset(y: -1.9 * u)
                    .rotationEffect(.degrees(Double(arrivals) * 360))
                    .animation(glide(0.7), value: arrivals)
                Capsule().frame(width: 1.7 * u, height: 3.2 * u).offset(y: -1.3 * u)
                    .rotationEffect(.degrees(90 + Double(arrivals) * 30))
                    .animation(glide(0.7), value: arrivals)
            }
        case .trash:
            // The lid lifts: Apple's own layered motion for the bin.
            sf("trash.fill", 0.95)
                .symbolEffect(.bounce.up.byLayer, value: arrivals)
        case .globe:
            // Turns to show the other side of the world.
            swap("globe.americas.fill", "globe.europe.africa.fill")
        case .importing:
            // The arrow drops into the tray.
            ZStack {
                sf("tray", 0.95).offset(y: 1.6 * u)
                sf("arrow.down", 0.55, .bold)
                    .offset(y: (on ? 0.4 : -3.2) * u)
                    .animation(glide(), value: on)
            }
        case .terminal:
            ZStack {
                sf("chevron.right", 0.62, .bold)
                    .offset(x: (on ? -1.8 : -3) * u, y: -1 * u)
                Capsule().frame(width: 4.5 * u, height: 1.7 * u)
                    .offset(x: (on ? 4 : 2.8) * u, y: 3.2 * u)
            }
            .animation(glide(), value: on)
        case .copy:
            ZStack {
                sf("doc", 0.78, .semibold)
                    .offset(x: (on ? -2.6 : -1.8) * u, y: (on ? -2 : -1.4) * u)
                sf("doc.fill", 0.78)
                    .offset(x: (on ? 2.6 : 1.8) * u, y: (on ? 2 : 1.4) * u)
            }
            .animation(glide(), value: on)
        case .permissions:
            // The hand goes up.
            sf("hand.raised.fill", 0.95)
                .offset(y: on ? -1.4 * u : 0)
                .rotationEffect(.degrees(on ? -8 : 0), anchor: .bottom)
                .animation(glide(), value: on)
        case .code:
            // The brackets open.
            ZStack {
                sf("chevron.left", 0.6, .bold).offset(x: (on ? -4.4 : -3.4) * u)
                sf("chevron.right", 0.6, .bold).offset(x: (on ? 4.4 : 3.4) * u)
                sf("line.diagonal", 0.7, .bold)
            }
            .animation(glide(), value: on)
        }
    }
}

/// The palette's round Liquid Glass buttons (its settings button and the
/// settings' X): the system's glass button with an SF Symbol, both the same
/// size, still.
final class GlassIconButton: NSButton {
    init(symbol: String, label: String, weight: NSFont.Weight = .regular, pointSize: CGFloat = 14) {
        super.init(frame: .zero)
        bezelStyle = .glass
        borderShape = .circle
        controlSize = .large
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        imagePosition = .imageOnly
        toolTip = label
    }

    required init?(coder: NSCoder) { fatalError() }
}
