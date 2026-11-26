import SwiftUI

// Small pieces shared by Photos, Files, Camera and Web. They build on
// Core/Design and add nothing new to the look.

/// A round icon button on a flat grey disc, for bars and overlays.
struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 40
    var fill: Color = Theme.raised
    var tint: Color = Theme.primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .pressable(configuration.isPressed, scale: 0.9)
    }
}

/// The same disc for a menu's label, which a button style can't reach.
struct CircleIcon: View {
    var symbol: String
    var size: CGFloat = 38
    var fill: Color = Theme.raised
    var tint: Color = Theme.primary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .contentShape(Circle())
    }
}

/// How far an import has got.
struct ImportProgress: Equatable {
    var done = 0
    var total: Int

    var fraction: CGFloat { total == 0 ? 0 : CGFloat(done) / CGFloat(total) }
}

/// Calm progress while things are added: one line and a thin bar.
struct ImportProgressBar: View {
    var progress: ImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.total > 1 ? "Adding \(min(progress.done + 1, progress.total)) of \(progress.total)" : "Adding…")
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
                .contentTransition(.numericText())
            GeometryReader { geo in
                Capsule().fill(Theme.raised)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.primary)
                            .frame(width: max(6, geo.size.width * progress.fraction))
                    }
            }
            .frame(height: 4)
        }
        .animation(Theme.smooth, value: progress)
        .accessibilityElement(children: .combine)
    }
}

/// "42 of 50 on Free · See plans" under Photos and Files on the free plan.
/// The count is this space's own, so it says nothing about other spaces.
struct FreeCountLine: View {
    var used: Int
    var onPlans: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(FreePlan.countLine(used: used) + " ·")
                .foregroundStyle(Theme.secondary)
                .contentTransition(.numericText())
            Button("See plans", action: onPlans)
                .foregroundStyle(Theme.primary)
                .underline()
                .accessibilityIdentifier("free.seePlans")
        }
        .font(.subheadline)
        .animation(Theme.snappy, value: used)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("free.count")
    }
}

/// A big screen title with an optional quiet line under it.
struct ScreenHeader: View {
    var title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TwoToneTitle(key: title)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An empty screen: Casita's glyph, one line, and what to do about it.
struct EmptyStateView<Actions: View>: View {
    var glyph: Glyph
    var line: String
    @ViewBuilder var actions: () -> Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(spacing: 22) {
            GlyphView(glyph: glyph, lineWidth: 1.5)
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.primary)
                .frame(width: 96, height: 96)
                .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.surface))
                .reveal(0, active: shown || reduceMotion)
            Text(line)
                .font(.body)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
                .fixedSize(horizontal: false, vertical: true)
                .reveal(1, active: shown || reduceMotion)
            VStack(spacing: 6) { actions() }
                .padding(.top, 4)
                .reveal(2, active: shown || reduceMotion)
        }
        .column()
        .onAppear { shown = true }
    }
}

extension View {
    /// The screen's name in the bar once its big title has scrolled away.
    /// Apply to the screen's ScrollView. `readable` keeps the content in a
    /// column on a wide screen; a photo grid passes false and uses it all.
    func collapsingTitle(_ title: String, readable: Bool = true) -> some View {
        modifier(CollapsingTitle(title: title))
            .readableColumn(readable ? Adaptive.readable : .infinity)
    }
}

private struct CollapsingTitle: ViewModifier {
    let title: String
    @State private var collapsed = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 48
            } action: { _, now in
                withAnimation(Theme.snappy) { collapsed = now }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .opacity(collapsed ? 1 : 0)
                        .offset(y: collapsed ? 0 : 6)
                        .accessibilityHidden(!collapsed)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    }
}

/// "1 photo", "3 videos".
func counted(_ n: Int, _ one: String, _ many: String) -> String {
    "\(n) \(n == 1 ? one : many)"
}
