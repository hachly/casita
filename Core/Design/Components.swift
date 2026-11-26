import SwiftUI

// MARK: Buttons

/// The one main action on a screen: a white capsule with black text.
struct PrimaryButtonStyle: ButtonStyle {
    var tint = Theme.primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(tint.opacity(isEnabled ? 1 : 0.22)))
            .foregroundStyle(Color.black.opacity(isEnabled ? 1 : 0.6))
            .contentShape(Capsule())
            .pressable(configuration.isPressed)
    }
}

/// A quieter full-width action: a grey capsule with white text.
struct RaisedButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(Theme.raised))
            .foregroundStyle(destructive ? Theme.danger : Theme.primary)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            .pressable(configuration.isPressed)
    }
}

/// Text only, for "Not now", "Back" and the like.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(Theme.secondary)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// Any custom tappable thing (tiles, cards, keys): shrinks a little under
/// the finger with a light tap.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressable(configuration.isPressed, scale: scale)
    }
}

extension View {
    /// Spring scale under the finger and a light tap as it goes down.
    func pressable(_ pressed: Bool, scale: CGFloat = 0.97) -> some View {
        self.scaleEffect(pressed ? scale : 1)
            .animation(Theme.snappy, value: pressed)
            .onChange(of: pressed) { _, down in if down { Haptics.play(.tap) } }
    }
}

// MARK: Text

/// The store's two-tone headline: a grey lead line, then the white key line.
struct TwoToneTitle: View {
    var lead: String?
    var key: String
    var font: Font = .casitaTitle
    var alignment: TextAlignment = .leading

    var body: some View {
        Group {
            if let lead {
                Text("\(Text(lead).foregroundStyle(Theme.quiet))\n\(Text(key).foregroundStyle(Theme.primary))")
            } else {
                Text(key).foregroundStyle(Theme.primary)
            }
        }
        .font(font)
        .tracking(-0.6)
        .lineSpacing(2)
        .multilineTextAlignment(alignment)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Under this space": small and quiet, in normal case like every other
/// heading in Casita.
struct SectionLabel: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.casitaLabel)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Surfaces

/// A grey card on black.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
    }
}

/// One row of a list: optional glyph, title, optional detail, optional trailing.
struct CasitaRow<Trailing: View>: View {
    var glyph: Glyph? = nil
    var symbol: String? = nil
    var title: String
    var detail: String? = nil
    var tint = Theme.primary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            if let glyph {
                GlyphView(glyph: glyph, lineWidth: 1.7).frame(width: 22, height: 22).foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised))
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(tint)
                if let detail { Text(detail).font(.footnote).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
    }
}

extension CasitaRow where Trailing == AnyView {
    /// A row with a chevron, for rows that open something.
    init(glyph: Glyph? = nil, symbol: String? = nil, title: String, detail: String? = nil, tint: Color = Theme.primary, chevron: Bool = true) {
        self.init(glyph: glyph, symbol: symbol, title: title, detail: detail, tint: tint) {
            AnyView(Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiary).opacity(chevron ? 1 : 0))
        }
    }
}

// MARK: Motion

extension View {
    /// Staggered entrance: fades up into place `index` steps after `active`
    /// turns true.
    func reveal(_ index: Int, active: Bool, step: Double = 0.07) -> some View {
        self.opacity(active ? 1 : 0)
            .offset(y: active ? 0 : 14)
            .blur(radius: active ? 0 : 4)
            .animation(Theme.smooth.delay(Double(index) * step), value: active)
    }

    /// A short message in a pill at the top that hides itself. At the top it
    /// never covers a screen's main button.
    func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }

    /// The same message for a screen with a bar and a big title under it:
    /// shown in the bar's row by whoever holds the `ToastCenter` above, so
    /// it never lands on the title. With nobody above, an ordinary `toast`.
    func barToast(_ message: Binding<String?>) -> some View {
        modifier(BarToastModifier(message: message))
    }
}

/// Holds the one short message of a navigation stack, so the stack can
/// show it above its bar. Put it in `\.toastCenter` and call `toast` with
/// its message on the stack itself.
@MainActor @Observable
final class ToastCenter {
    var message: String?
    init() {}
}

extension EnvironmentValues {
    @Entry var toastCenter: ToastCenter? = nil
}

private struct BarToastModifier: ViewModifier {
    @Binding var message: String?
    @Environment(\.toastCenter) private var center

    func body(content: Content) -> some View {
        if let center {
            content.onChange(of: message) { _, new in
                guard let new else { return }
                center.message = new
                message = nil
            }
        } else {
            content.toast($message)
        }
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Capsule().fill(.white))
                    // Level with a bar's back button.
                    .padding(.top, 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(1.8))
                        withAnimation(Theme.smooth) { self.message = nil }
                    }
            }
        }
        .animation(Theme.bouncy, value: message)
    }
}
