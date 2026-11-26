import SwiftUI

// Onboarding's own controls, drawn from SwiftUI shapes and plain buttons
// rather than UIKit-backed system controls, each with its haptic.

/// A row of choices with a white capsule that slides to the chosen one.
struct SlidingSegments<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var label: (Value) -> String
    var identifier: (Value) -> String
    var small = false

    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button {
                    guard !on else { return }
                    Haptics.play(.select)
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(small ? .footnote.weight(.semibold).monospacedDigit() : .subheadline.weight(.semibold))
                        .foregroundStyle(on ? Color.black : Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: small ? 32 : 40)
                        .background {
                            if on {
                                Capsule().fill(Color.white).matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(SquishStyle())
                .accessibilityIdentifier(identifier(option))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.surface))
    }
}

/// Shrinks under the finger with no haptic of its own (the control plays one).
struct SquishStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// The unlock method switch: Numbers, Dots, Password.
struct MethodPicker: View {
    @Binding var method: EntryView.Method

    var body: some View {
        SlidingSegments(options: EntryView.Method.allCases, selection: $method, label: Self.label, identifier: Self.identifier)
    }

    static func label(_ method: EntryView.Method) -> String {
        switch method {
        case .numbers: "Numbers"
        case .dots: "Dots"
        case .letters: "Password"
        }
    }

    static func identifier(_ method: EntryView.Method) -> String {
        switch method {
        case .numbers: "onboarding.method.numbers"
        case .dots: "onboarding.method.dots"
        case .letters: "onboarding.method.password"
        }
    }
}

/// The dots grid size, 3×3 to 6×6. Codes come out of `DotsPad` already
/// naming their grid, so the size never needs storing.
struct GridSizePicker: View {
    @Binding var size: Int

    var body: some View {
        SlidingSegments(options: DotsCode.sizes, selection: $size, label: { "\($0)×\($0)" },
                        identifier: { "onboarding.dots.size.\($0)" }, small: true)
            .frame(maxWidth: 260)
    }
}

/// A switch drawn in SwiftUI: white when on, grey when off. The knob
/// stretches under the finger.
struct CasitaToggleStyle: ToggleStyle {
    /// Played when the switch turns on; turning off always plays a select.
    var onHaptic: Haptics.Kind = .select

    func makeBody(configuration: Configuration) -> some View {
        Button {
            Haptics.play(configuration.isOn ? .select : onHaptic)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) { configuration.isOn.toggle() }
        } label: {
            configuration.label
        }
        .buttonStyle(SwitchRow(isOn: configuration.isOn))
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

private struct SwitchRow: ButtonStyle {
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 14) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.white : Theme.raised)
                Capsule()
                    .fill(isOn ? Color.black : Theme.secondary)
                    .frame(width: configuration.isPressed ? 32 : 26, height: 26)
                    .padding(3)
            }
            .frame(width: 54, height: 32)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
        }
        .contentShape(Rectangle())
    }
}

/// The typed code's dots: one grey dot when empty, a white dot per digit,
/// each popping in.
struct SetupCodeDots: View {
    var count: Int

    var body: some View {
        // Six rings like the entry screen, which also shows the 6-digit minimum.
        HStack(spacing: 12) {
            ForEach(0..<min(max(6, count), 16), id: \.self) { i in
                ZStack {
                    Circle().strokeBorder(Color.white.opacity(i < count ? 0 : 0.3), lineWidth: 1.5)
                    Circle().fill(Color.white).scaleEffect(i < count ? 1 : 0.001)
                }
                .frame(width: 12, height: 12)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: count)
        .accessibilityElement()
        .accessibilityLabel("\(count) digits")
    }
}

/// A shake on every change of `trigger`; a quick dip in opacity instead
/// with Reduce Motion.
struct ShakeOnChange: ViewModifier {
    var trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let calm = reduceMotion
        return content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, x in
            view.offset(x: calm ? 0 : x).opacity(calm ? 1 - abs(x) / 24 : 1)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-12, duration: 0.05)
                LinearKeyframe(11, duration: 0.08)
                LinearKeyframe(-8, duration: 0.08)
                LinearKeyframe(5, duration: 0.07)
                SpringKeyframe(0, duration: 0.25, spring: .bouncy)
            }
        }
    }
}

/// The check from the art grid, as a shape that trims.
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        return Art.check().applying(CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 12 * s).scaledBy(x: s, y: s))
    }
}

/// A ring and a check that draw themselves once `drawn` turns true.
struct CheckBadge: View {
    var drawn: Bool
    var size: CGFloat = 56
    var tint: Color = .white

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.12), lineWidth: max(1.5, size / 26))
            Circle()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: max(1.5, size / 26), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.55), value: drawn)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: max(2, size / 18), lineCap: .round, lineJoin: .round))
                .padding(size * 0.18)
                .animation(.easeOut(duration: 0.35).delay(0.4), value: drawn)
        }
        .frame(width: size, height: size)
        .scaleEffect(drawn ? 1 : 0.86)
        .animation(Theme.bouncy, value: drawn)
        .accessibilityHidden(true)
    }
}

/// The welcome pages' progress: one segment per page, filled up to this one.
struct StoryBar: View {
    var count: Int
    var current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .overlay {
                        Rectangle().fill(Color.white)
                            .scaleEffect(x: i <= current ? 1 : 0.0001, y: 1, anchor: .leading)
                            .animation(.smooth(duration: 0.6).delay(i == current ? 0.08 : 0), value: current)
                    }
                    .clipShape(Capsule())
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A thin bar for how far along something is.
struct ProgressLine: View {
    var value: Double
    var height: CGFloat = 4

    var body: some View {
        Capsule()
            .fill(Color.white.opacity(0.14))
            .overlay {
                Rectangle().fill(Color.white)
                    .scaleEffect(x: max(0.0001, min(1, value)), y: 1, anchor: .leading)
            }
            .clipShape(Capsule())
            .frame(height: height)
    }
}

/// Three dots that breathe in turn while something works.
struct BusyDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.7 : 0.3 + 0.7 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.9)))
                }
            }
        }
        .accessibilityLabel("Working")
    }
}
