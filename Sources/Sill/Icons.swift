import AppKit
import SwiftUI

/// The settings' icons: Apple's own SF Symbols, each playing the animation
/// Apple drew for it (its layers moving one after another, a turn, a
/// wiggle, a twinkle) once when the pointer comes onto its row. Nothing
/// else in the palette moves. Reduce Motion is honoured by the system.
enum IconKind {
    case search, appearance, corners, reopen, previews, pip, sleep, claude
    case shield, key, link, connected, history, trash, globe, importing
    case terminal, copy, code
}

struct HoverIcon: View {
    let kind: IconKind
    /// Changed each time the pointer comes onto the row: plays once.
    var plays: Int
    var size: CGFloat = 13

    var body: some View {
        let image = Image(systemName: Self.symbol(kind)).font(.system(size: size, weight: .medium))
        switch kind {
        case .search, .corners, .key, .link, .shield, .globe, .terminal, .code:
            image.symbolEffect(.wiggle, value: plays)
        case .appearance:
            image.symbolEffect(.rotate.wholeSymbol, value: plays)
        case .reopen:
            image.symbolEffect(.rotate.counterClockwise.wholeSymbol, value: plays)
        case .history:
            image.symbolEffect(.rotate.byLayer, value: plays)
        case .previews, .pip, .copy:
            image.symbolEffect(.wiggle.byLayer, value: plays)
        case .sleep:
            image.symbolEffect(.breathe.byLayer, value: plays)
        case .claude:
            image.symbolEffect(.variableColor.iterative, value: plays)
        case .trash:
            image.symbolEffect(.bounce.up.byLayer, value: plays)
        case .importing:
            image.symbolEffect(.bounce.down.byLayer, value: plays)
        case .connected:
            image.symbolEffect(.bounce, value: plays)
        }
    }

    static func symbol(_ kind: IconKind) -> String {
        switch kind {
        case .search: "magnifyingglass"
        case .appearance: "circle.lefthalf.filled"
        case .corners: "macwindow"
        case .reopen: "arrow.counterclockwise"
        case .previews: "rectangle.on.rectangle"
        case .pip: "pip.fill"
        case .sleep: "moon.zzz.fill"
        case .claude: "sparkles"
        case .shield: "checkmark.shield.fill"
        case .key: "key.fill"
        case .link: "link"
        case .connected: "checkmark"
        case .history: "clock.arrow.circlepath"
        case .trash: "trash.fill"
        case .globe: "globe"
        case .importing: "square.and.arrow.down.fill"
        case .terminal: "apple.terminal.fill"
        case .copy: "doc.on.doc.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
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
