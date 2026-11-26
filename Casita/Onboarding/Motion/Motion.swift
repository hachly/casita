import SwiftUI

// Onboarding's motion kit. Illustrations are pure functions of a clock: a
// scene takes `t`, seconds into its loop, and draws that moment. One clock
// drives the pixels and the haptics, so every tap lands on its frame.

/// Easing for scenes drawn from a clock.
enum Ease {
    /// 0 before `from`, 1 after `to`, straight in between.
    static func progress(_ t: Double, _ from: Double, _ to: Double) -> Double {
        guard to > from else { return t >= to ? 1 : 0 }
        return min(1, max(0, (t - from) / (to - from)))
    }

    static func out(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    static func `in`(_ p: Double) -> Double { p * p * p }
    static func inOut(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }

    /// Overshoots a little, then lands.
    static func back(_ p: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }

    /// A spring landing on 1 with one soft overshoot.
    static func settle(_ p: Double) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        return 1 - exp(-6.5 * p) * cos(3.2 * .pi * p)
    }

    /// A shake that dies away, between -1 and 1.
    static func shake(_ p: Double) -> Double {
        p <= 0 || p >= 1 ? 0 : sin(p * .pi * 6) * (1 - p)
    }

    /// 0 → 1 → 0.
    static func pulse(_ p: Double) -> Double {
        p <= 0 || p >= 1 ? 0 : sin(p * .pi)
    }

    /// Rises over `rise` from `a`, holds, falls over `fall` ending at `b`.
    static func window(_ t: Double, _ a: Double, _ b: Double, rise: Double = 0.3, fall: Double = 0.3) -> Double {
        min(out(progress(t, a, a + rise)), 1 - inOut(progress(t, b - fall, b)))
    }

    static func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
}

/// A haptic at a moment of a scene.
struct Beat {
    var time: Double
    var kind: Haptics.Kind

    init(_ time: Double, _ kind: Haptics.Kind) {
        self.time = time
        self.kind = kind
    }
}

/// Runs `content(t)` while `active`, with `t` seconds into the loop, and
/// plays `beats` in time with it for the first `hapticLoops` loops, so a page
/// left open goes quiet. Stopped, it shows `rest`; with Reduce Motion it
/// shows `still` and plays nothing. `once` plays a single pass and holds the
/// last frame.
struct LoopClock<Content: View>: View {
    var period: Double
    var active: Bool
    var rest: Double = 0
    var still: Double
    var beats: [Beat] = []
    var hapticLoops = 1
    var once = false
    @ViewBuilder var content: (Double) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var held = false

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: start == nil || held)) { timeline in
            content(time(at: timeline.date))
        }
        .task(id: active && !reduceMotion) { await run() }
    }

    private func time(at date: Date) -> Double {
        if reduceMotion { return still }
        if held { return period }
        guard let start else { return rest }
        let elapsed = max(0, date.timeIntervalSince(start))
        return once ? min(elapsed, period) : elapsed.truncatingRemainder(dividingBy: period)
    }

    private func run() async {
        held = false
        guard active, !reduceMotion else {
            start = nil
            return
        }
        let begin = Date.now
        start = begin
        let loops = once ? 1 : hapticLoops
        for loop in 0..<loops {
            for beat in beats {
                let wait = begin.addingTimeInterval(Double(loop) * period + beat.time).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled else { return }
                Haptics.play(beat.kind)
            }
        }
        if once {
            let wait = begin.addingTimeInterval(period).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            held = true
        }
    }
}

/// Lays out a scene drawn at a fixed design size, scaled to fit what it is
/// given. Too small to read, it steps aside.
struct SceneBox<Content: View>: View {
    var size: CGSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            content()
                .frame(width: size.width, height: size.height)
                .scaleEffect(max(0.01, scale))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .opacity(scale < 0.38 ? 0 : 1)
        }
        .accessibilityHidden(true)
    }
}

/// Plays haptics on a schedule from now, cancelled with the calling task.
@MainActor
enum Choreo {
    static func play(_ beats: [Beat]) async {
        let begin = Date.now
        for beat in beats {
            let wait = begin.addingTimeInterval(beat.time).timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            Haptics.play(beat.kind)
        }
    }
}

extension EnvironmentValues {
    /// Short screens (iPhone SE): smaller titles, tighter spacing, smaller art.
    @Entry var onboardingCompact = false
}

extension AnyTransition {
    /// One onboarding step arriving from the side it is going to (right
    /// going forward, left going back) as the last one sinks away. The
    /// removal has no direction: a leaving view keeps the transition it was
    /// last drawn with, which predates the move.
    static func onboardingStep(forward: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: forward ? 32 : -32)),
            removal: .opacity.combined(with: .scale(scale: 0.97))
        )
    }
}
