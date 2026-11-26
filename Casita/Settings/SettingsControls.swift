import SwiftUI

// Settings draws its own switches and choices from SwiftUI shapes and
// buttons. UIKit-backed system controls (segmented Picker, Toggle) have
// ignored taps in this app in the simulator; plain buttons work.

/// A titled group: a label, a card of rows split by hairlines,
/// and an optional footnote.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                SectionLabel(title).padding(.horizontal, 6)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                        if row.id != rows.last?.id {
                            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 64)
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// Rows inside a group light up under the finger instead of shrinking,
/// with one light tap as the finger goes down.
struct RowPressStyle: ButtonStyle {
    var haptic = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Color.white.opacity(configuration.isPressed ? 0.06 : 0).allowsHitTesting(false))
            .animation(Theme.snappy, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in
                if down, haptic { Haptics.play(.tap) }
            }
    }
}

/// A row-shaped button around a label someone else wrote (Back up now).
struct RowButtonStyle: ButtonStyle {
    var symbol: String
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised))
            configuration.label.font(.body.weight(.medium))
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiary)
        }
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .background(Theme.surface)
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .overlay(Color.white.opacity(configuration.isPressed ? 0.06 : 0).allowsHitTesting(false))
        .animation(Theme.snappy, value: configuration.isPressed)
        .onChange(of: configuration.isPressed) { _, down in if down { Haptics.play(.tap) } }
    }
}

/// A row with a value on the right; nothing to tap.
struct SettingsValueRow: View {
    var glyph: Glyph?
    var symbol: String?
    var title: String
    var value: String

    var body: some View {
        CasitaRow(glyph: glyph, symbol: symbol, title: title) {
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .contentTransition(.numericText())
                .animation(Theme.snappy, value: value)
        }
        .accessibilityElement(children: .combine)
    }
}

/// An on/off row with Casita's own switch: white when on (gold for a
/// security switch), grey when off.
struct SettingsSwitchRow: View {
    var glyph: Glyph?
    var symbol: String?
    var title: String
    var detail: String?
    var onTint = Color.white
    let isOn: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        Button {
            onChange(!isOn)
            Haptics.play(.select)
        } label: {
            CasitaRow(glyph: glyph, symbol: symbol, title: title, detail: detail) {
                SwitchTrack(isOn: isOn, onTint: onTint)
            }
        }
        .buttonStyle(RowPressStyle(haptic: false))
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

extension SettingsSwitchRow {
    init(glyph: Glyph? = nil, symbol: String? = nil, title: String, detail: String? = nil, onTint: Color = .white, isOn: Binding<Bool>) {
        self.init(glyph: glyph, symbol: symbol, title: title, detail: detail, onTint: onTint, isOn: isOn.wrappedValue) { isOn.wrappedValue = $0 }
    }
}

private struct SwitchTrack: View {
    var isOn: Bool
    var onTint: Color

    var body: some View {
        Capsule()
            .fill(isOn ? onTint : Color(white: 0.2))
            // An off switch on a card needs an edge to read as a switch.
            .overlay(Capsule().strokeBorder(Color.white.opacity(isOn ? 0 : 0.25), lineWidth: 1.5))
            .frame(width: 50, height: 30)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? Color.black : Color(white: 0.55))
                    .padding(3)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isOn)
    }
}

/// A row showing the current choice; tapping it opens the choices in
/// place, and picking one closes them again.
struct SettingsChoiceRow<Value: Hashable>: View {
    var glyph: Glyph?
    var symbol: String?
    var title: String
    var options: [Value]
    let selection: Value
    var label: (Value) -> String
    /// The row's accessibility identifier; each choice adds ".<name>".
    var identifier: String
    var optionName: (Value) -> String
    var onSelect: (Value) -> Void
    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.play(.soft)
                withAnimation(Theme.snappy) { open.toggle() }
            } label: {
                CasitaRow(glyph: glyph, symbol: symbol, title: title) {
                    HStack(spacing: 8) {
                        Text(label(selection))
                            .foregroundStyle(Theme.secondary)
                            .contentTransition(.opacity)
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.tertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                }
            }
            .buttonStyle(RowPressStyle(haptic: false))
            .accessibilityValue(label(selection))
            .accessibilityHint(open ? "Hides the choices" : "Shows the choices")
            .accessibilityIdentifier(identifier)

            if open {
                VStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        let chosen = option == selection
                        Button {
                            pick(option)
                        } label: {
                            HStack {
                                Text(label(option))
                                    .font(.body.weight(chosen ? .semibold : .regular))
                                    .foregroundStyle(chosen ? Theme.primary : Theme.secondary)
                                Spacer()
                                if chosen {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(.leading, 64)
                            .padding(.trailing, 18)
                            .frame(minHeight: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowPressStyle(haptic: false))
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                        .accessibilityIdentifier("\(identifier).\(optionName(option))")
                    }
                }
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    private func pick(_ option: Value) {
        Haptics.play(.select)
        withAnimation(Theme.bouncy) { onSelect(option) }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(Theme.snappy) { open = false }
        }
    }
}
