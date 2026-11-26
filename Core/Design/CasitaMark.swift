import SwiftUI

/// Where each part of the winking house is at one moment. `final` is the
/// logo as on the icon.
struct MarkPose: Equatable, Sendable {
    var house: CGFloat = 1        // scale, 0...1+
    var houseOpacity: CGFloat = 1
    var rise: CGFloat = 0         // units the house sits below its place
    var pupil: CGFloat = 1        // left pupil scale
    var glint: CGFloat = 1
    var rightEye: CGFloat = 0     // the open right eye before the wink
    var rightOpen: CGFloat = 0    // 1 open, 0 squeezed shut
    var wink: CGFloat = 1         // the wink arc drawn so far
    var smile: CGFloat = 1        // the smile drawn so far, from the middle out
    var look: CGFloat = 0         // left pupil's sideways glance, in units

    static let final = MarkPose()
    static let hidden = MarkPose(house: 0.55, houseOpacity: 0, rise: 60, pupil: 0, glint: 0, rightEye: 0, rightOpen: 1, wink: 0, smile: 0)
}

/// The winking house, drawn from the icon master (1024 units). `onDark` is
/// a white house with a black face, like the dark icon; `onLight` is the
/// black house of the light icon.
struct CasitaMark: View {
    enum Style { case onDark, onLight }
    var style: Style = .onDark
    var pose: MarkPose = .final

    private var house: Color { style == .onDark ? .white : Color(white: 0.04) }
    private var face: Color { style == .onDark ? Color(white: 0.04) : .white }

    var body: some View {
        Canvas { ctx, size in
            let unit = min(size.width, size.height) / 1024
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: unit * 0.86, y: unit * 0.86)
            // The house's middle (583) sits at the centre of the frame.
            ctx.translateBy(x: -512, y: -583 + pose.rise)

            ctx.opacity = pose.houseOpacity
            var art = ctx
            art.translateBy(x: 512, y: 583)
            art.scaleBy(x: pose.house, y: pose.house)
            art.translateBy(x: -512, y: -583)
            let roof = Path { p in
                p.move(to: CGPoint(x: 0, y: 444))
                p.addLine(to: CGPoint(x: 512, y: 142))
                p.addLine(to: CGPoint(x: 1024, y: 444))
                p.addLine(to: CGPoint(x: 1024, y: 1024))
                p.addLine(to: CGPoint(x: 0, y: 1024))
                p.closeSubpath()
            }
            // Filled, then stroked in the same colour with round joins: soft corners.
            art.fill(roof, with: .color(house))
            art.stroke(roof, with: .color(house), style: StrokeStyle(lineWidth: 64, lineJoin: .round))

            if style == .onLight {
                art.fill(circle(311.5, 544.5, 134.5 * pose.pupil), with: .color(face))
            }
            let pupilColor = style == .onDark ? face : house
            art.fill(circle(333 + pose.look, 544, 73 * pose.pupil), with: .color(pupilColor))
            art.opacity = pose.houseOpacity * pose.glint
            art.fill(circle(361.5 + pose.look * 0.8, 519.5, 23.5 * pose.pupil), with: .color(style == .onDark ? house : face))
            art.opacity = pose.houseOpacity

            // The right eye opens, squeezes shut, and becomes the wink.
            if pose.rightEye > 0.01, pose.rightOpen > 0.02 {
                let r = 73 * pose.rightEye
                let open = Path(ellipseIn: CGRect(x: 713.5 - r, y: 544 - r * pose.rightOpen, width: 2 * r, height: 2 * r * pose.rightOpen))
                art.fill(open, with: .color(pupilColor))
            }
            let line = StrokeStyle(lineWidth: 38, lineCap: .round)
            if pose.wink > 0.001 {
                let wink = Path { p in
                    p.move(to: CGPoint(x: 600, y: 567))
                    p.addQuadCurve(to: CGPoint(x: 827, y: 567), control: CGPoint(x: 713.5, y: 475))
                }
                art.stroke(wink.trimmedPath(from: 0, to: pose.wink), with: .color(face), style: line)
            }
            if pose.smile > 0.001 {
                let smile = Path { p in
                    p.move(to: CGPoint(x: 394, y: 765.5))
                    p.addQuadCurve(to: CGPoint(x: 629, y: 765.5), control: CGPoint(x: 511.5, y: 847.5))
                }
                art.stroke(smile.trimmedPath(from: 0.5 - pose.smile / 2, to: 0.5 + pose.smile / 2), with: .color(face), style: line)
            }
        }
        .accessibilityLabel("Casita")
    }

    private func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
}

/// The logo's entrance: the house lands, the eye opens, the other eye winks,
/// the smile draws, a glance; each beat has its haptic. About 2.7 seconds.
/// Reduce Motion shows the finished logo at once.
struct CasitaMarkIntro: View {
    var style: CasitaMark.Style = .onDark
    /// Starts the animation; flip it to play again.
    var play = true
    var onFinished: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?
    @State private var finished = false

    static let duration: TimeInterval = 2.7

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { timeline in
            let t = start.map { timeline.date.timeIntervalSince($0) } ?? (finished || reduceMotion ? Self.duration : 0)
            CasitaMark(style: style, pose: Self.pose(at: t))
        }
        .task(id: play) {
            guard play else { return }
            if reduceMotion { onFinished(); return }
            finished = false
            start = .now
            await beats()
            try? await Task.sleep(for: .seconds(Self.duration - 1.6))
            finished = true
            start = nil
            onFinished()
        }
    }

    /// The haptics, in time with `pose(at:)`.
    private func beats() async {
        let beats: [(TimeInterval, Haptics.Kind)] = [(0.2, .thud), (0.62, .soft), (0.88, .tap), (1.36, .wink), (1.6, .soft)]
        var last: TimeInterval = 0
        for (time, kind) in beats {
            try? await Task.sleep(for: .seconds(time - last))
            Haptics.play(kind)
            last = time
        }
    }

    /// The logo at `t` seconds into the entrance.
    static func pose(at t: TimeInterval) -> MarkPose {
        if t >= duration { return .final }
        var pose = MarkPose.hidden
        let house = progress(t, 0, 0.62)
        pose.house = 0.55 + 0.45 * backOut(house)
        pose.houseOpacity = min(1, house * 3)
        pose.rise = 60 * (1 - cubicOut(house))
        pose.pupil = backOut(progress(t, 0.55, 0.85))
        pose.glint = progress(t, 0.8, 0.95)
        pose.rightEye = backOut(progress(t, 0.82, 1.08))
        pose.rightOpen = 1 - cubicIn(progress(t, 1.3, 1.42))
        pose.wink = cubicOut(progress(t, 1.36, 1.58))
        pose.smile = cubicInOut(progress(t, 1.5, 1.95))
        // A glance left, then right, then home.
        let glance = progress(t, 2.0, 2.65)
        pose.look = glance <= 0 ? 0 : CGFloat(sin(glance * .pi * 2)) * -14
        return pose
    }

    private static func progress(_ t: TimeInterval, _ from: TimeInterval, _ to: TimeInterval) -> CGFloat {
        CGFloat(min(1, max(0, (t - from) / (to - from))))
    }

    private static func cubicOut(_ p: CGFloat) -> CGFloat { 1 - pow(1 - p, 3) }
    private static func cubicIn(_ p: CGFloat) -> CGFloat { p * p * p }
    private static func cubicInOut(_ p: CGFloat) -> CGFloat { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
    private static func backOut(_ p: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }
}
