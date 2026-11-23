import AppKit
import SwiftUI

/// Settings inside the ⌘T palette: the slider button in its corner turns the
/// card into a short list of what's most often changed, with a glass X at
/// the top right (or Esc) to go back. The rest is one row away in the full
/// Settings window.
struct PaletteSettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    var onBack: () -> Void
    var onAll: () -> Void
    /// Changed each time the view comes in: the icons give a small bounce.
    var arrival: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .symbolEffect(.bounce, value: arrival)
                Text("Settings")
                    .font(.system(size: 21))
                Spacer()
                Button(action: onBack) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .help("Back")
                .accessibilityLabel("Back")
            }
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .frame(height: Palette.fieldHeight)

            ScrollView {
                VStack(spacing: 0) {
                    row("circle.lefthalf.filled", .indigo, "Appearance", prefs.theme) {
                        Picker("", selection: $prefs.theme) {
                            ForEach(Theme.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    row("magnifyingglass", .blue, "Search with", prefs.engine) {
                        Picker("", selection: $prefs.engine) {
                            ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    toggle("checkmark.shield.fill", .green, "Block ads and trackers", $prefs.blocksAds)
                    toggle("pip.fill", .orange, "Float video when you switch tabs", $prefs.autoPictureInPicture)
                    toggle("rectangle.on.rectangle", .teal, "Preview tabs on hover", $prefs.showsTabPreviews)
                    toggle("sparkles", .brown, "Keep Claude ready", $prefs.keepsClaudeReady)
                    toggle("moon.zzz.fill", .purple, "Put idle tabs to sleep", $prefs.sleepsTabs)
                    Button(action: onAll) {
                        HStack(spacing: 12) {
                            tile("gearshape.fill", .gray)
                            Text("All Settings…").font(.system(size: 14))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func toggle(_ symbol: String, _ tint: Color, _ title: String, _ value: Binding<Bool>) -> some View {
        row(symbol, tint, title, value.wrappedValue) {
            Toggle("", isOn: value).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    /// An icon tile, a label and its control. The tile bounces when the
    /// setting changes, and with the rest when the list comes in.
    private func row<Value: Hashable, Control: View>(_ symbol: String, _ tint: Color, _ title: String, _ value: Value,
                                                     @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            tile(symbol, tint)
                .symbolEffect(.bounce, value: value)
            Text(title).font(.system(size: 14))
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    private func tile(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .symbolEffect(.bounce, value: arrival)
    }
}

/// A row that answers the pointer with the palette's own fill.
private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
            )
            .onHover { hovering = $0 }
    }
}
