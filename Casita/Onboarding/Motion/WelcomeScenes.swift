import SwiftUI

// The welcome pages' illustrations. Each is drawn from `t`, seconds into
// its loop, and lists the haptic beats that go with it.

/// Military-grade security: a gold shield draws itself, a padlock lands in
/// it and its shackle closes with a thud, then "AES-256" settles in.
struct ShieldScene: View {
    var t: Double

    static let size = CGSize(width: 260, height: 250)
    static let period = 6.4
    static let still = 3.2
    static var beats: [Beat] { [Beat(0.2, .soft), Beat(1.2, .soft), Beat(1.72, .thud), Beat(2.3, .tap)] }

    var body: some View {
        Canvas { ctx, _ in draw(ctx) }
    }

    private func draw(_ ctx: GraphicsContext) {
        let fade = 1 - Ease.inOut(Ease.progress(t, 5.7, 6.3))
        let center = CGPoint(x: 130, y: 108)
        let size: CGFloat = 196

        ctx.stroke(art: Art.shield(), center: center, size: size, color: .white.opacity(0.08), weight: 1.1)
        var gold = ctx
        gold.opacity = fade
        gold.stroke(art: Art.shield(), center: center, size: size, color: Theme.gold, weight: 1.1,
                    trim: CGFloat(Ease.inOut(Ease.progress(t, 0.2, 1.3))))

        // Two hairline ripples as the lock closes.
        for start in [1.72, 2.02] {
            let p = Ease.progress(t, start, start + 1.15)
            guard p > 0, p < 1 else { continue }
            var ripple = ctx
            ripple.opacity = (1 - p) * 0.55 * fade
            ripple.stroke(art: Art.shield(), center: center, size: size * CGFloat(1 + 0.3 * Ease.out(p)), color: Theme.gold, weight: 0.45)
        }

        let land = Ease.settle(Ease.progress(t, 1.15, 1.65))
        if land > 0.001 {
            var lock = ctx
            lock.opacity = min(1, land * 2) * fade
            lock.translateBy(x: center.x, y: center.y + 14)
            lock.scaleBy(x: CGFloat(0.6 + 0.4 * land), y: CGFloat(0.6 + 0.4 * land))
            let body = CGRect(x: -26, y: -8, width: 52, height: 40)
            let lift = CGFloat(14 * (1 - Ease.settle(Ease.progress(t, 1.55, 1.95))))
            let top = body.minY - 12 - lift
            var shackle = Path()
            shackle.move(to: CGPoint(x: -14, y: body.minY + 4))
            shackle.addLine(to: CGPoint(x: -14, y: top))
            shackle.addQuadCurve(to: CGPoint(x: 0, y: top - 14), control: CGPoint(x: -14, y: top - 14))
            shackle.addQuadCurve(to: CGPoint(x: 14, y: top), control: CGPoint(x: 14, y: top - 14))
            shackle.addLine(to: CGPoint(x: 14, y: body.minY + 4 - lift))
            lock.stroke(shackle, with: .color(Theme.gold), style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
            lock.fill(rounded: body, radius: 10, Theme.gold)
            lock.fill(circle: CGPoint(x: 0, y: body.midY - 3), radius: 4.5, .black)
            lock.fill(rounded: CGRect(x: -1.8, y: body.midY - 1, width: 3.6, height: 9), radius: 1.8, .black)
        }

        let words = Ease.out(Ease.progress(t, 2.05, 2.7))
        if words > 0.001 {
            var text = ctx
            text.opacity = words * fade
            text.draw(Text("AES-256")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .tracking(CGFloat(3 + 9 * (1 - words)))
                        .foregroundStyle(Theme.gold),
                      at: CGPoint(x: 130, y: CGFloat(232 + 6 * (1 - words))))
        }
    }
}

/// Fully secure: a wrong code takes the same check as any other, shakes,
/// and the next try waits, longer each time.
struct WaitScene: View {
    var t: Double

    static let size = CGSize(width: 260, height: 250)
    static let period = 8.0
    static let still = 3.0

    private static let attempts = [0.3, 4.3]
    private static let waits = ["1 min", "5 min", "15 min", "1 h"]

    static var beats: [Beat] {
        attempts.flatMap { a in
            (0..<6).map { Beat(a + 0.11 * Double($0), .tap) }
                + [Beat(a + 0.75, .soft), Beat(a + 1.55, .error), Beat(a + 2.05, .heartbeat)]
        }
    }

    var body: some View {
        Canvas { ctx, _ in draw(ctx) }
    }

    private func draw(_ ctx: GraphicsContext) {
        let center = CGPoint(x: 130, y: 100)
        let radius: CGFloat = 72
        let fade = 1 - Ease.inOut(Ease.progress(t, 7.4, 8.0))
        let index = t < Self.attempts[1] - 0.2 ? 0 : 1
        let r = t - Self.attempts[index]

        ctx.stroke(circle: center, radius: radius, .white.opacity(0.08), width: 3)

        // The check: the same sweep, the same length, every try.
        let check = Ease.progress(r, 0.75, 1.55)
        if check > 0, r < 1.75 {
            var c = ctx
            c.opacity = 1 - Ease.progress(r, 1.55, 1.75)
            c.stroke(circle: center, radius: radius, .white.opacity(0.85), width: 3, trim: CGFloat(Ease.inOut(check)))
        }
        // The wait, counting down in gold.
        let wait = Ease.progress(r, 1.95, 3.85)
        let waitIn = Ease.out(Ease.progress(r, 1.85, 2.2))
        if waitIn > 0 {
            var w = ctx
            w.opacity = waitIn * fade
            w.stroke(circle: center, radius: radius, Theme.gold, width: 3, trim: CGFloat(1 - wait))
            w.draw(Text(Self.waits[index]).font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.gold),
                   at: CGPoint(x: center.x, y: center.y + CGFloat(6 * (1 - waitIn))))
        }

        // The code's dots: typed, checked, shaken off.
        let dotsOut = Ease.progress(r, 1.75, 2.0)
        if dotsOut < 1 {
            var d = ctx
            d.opacity = 1 - dotsOut
            let shake = CGFloat(Ease.shake(Ease.progress(r, 1.55, 2.0))) * 11
            for i in 0..<6 {
                let typed = Self.attempts[index] + 0.11 * Double(i)
                let on = t >= typed && r < 1.75
                let pop = Ease.settle(Ease.progress(t, typed, typed + 0.28))
                let x = center.x + (CGFloat(i) - 2.5) * 15 + shake
                d.fill(circle: CGPoint(x: x, y: center.y), radius: on ? CGFloat(2.6 + 1.6 * pop) : 3, on ? .white : Color.white.opacity(0.24))
            }
        }

        // What happened, in words.
        let caption: String? = switch r {
        case 0.75..<1.55: "Checking"
        case 1.55..<2.05: "Wrong code"
        case 2.05..<3.85: "Next try waits"
        default: nil
        }
        if let caption {
            ctx.draw(Text(caption).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.tertiary),
                     at: CGPoint(x: center.x, y: center.y + radius + 22))
        }

        // The waits grow: 1 min, 5 min, 15 min, 1 h.
        let chipY: CGFloat = 232
        let widths: [CGFloat] = [50, 50, 58, 36]
        let total = widths.reduce(0, +) + 8 * 3
        var x = 130 - total / 2
        for (i, label) in Self.waits.enumerated() {
            let litAt = i < Self.attempts.count ? Self.attempts[i] + 1.85 : .infinity
            let lit = Ease.out(Ease.progress(t, litAt, litAt + 0.3)) * fade
            let rect = CGRect(x: x, y: chipY - 12, width: widths[i], height: 24)
            ctx.fill(rounded: rect, radius: 12, Color.white.opacity(0.06 + 0.06 * lit))
            if lit > 0.01 {
                var g = ctx
                g.opacity = lit
                g.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 12), with: .color(Theme.gold.opacity(0.7)), lineWidth: 1)
            }
            ctx.draw(Text(label).font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(lit > 0.5 ? Theme.gold : Theme.tertiary),
                     at: CGPoint(x: rect.midX, y: rect.midY))
            x += widths[i] + 8
        }
    }
}

/// Fully local: the line from the phone to the cloud is cut, and what was
/// leaving drops back in. The photos stay inside the phone.
struct LocalScene: View {
    var t: Double

    static let size = CGSize(width: 260, height: 250)
    static let period = 5.8
    static let still = 3.0
    static var beats: [Beat] {
        [Beat(0.2, .soft), Beat(1.3, .thud), Beat(1.82, .soft), Beat(2.0, .tap), Beat(2.15, .tap), Beat(2.3, .tap)]
    }

    private static let shades = [0.2, 0.12, 0.16, 0.09, 0.18, 0.13]

    var body: some View {
        Canvas { ctx, _ in draw(ctx) }
    }

    private func draw(_ ctx: GraphicsContext) {
        let reset = Ease.inOut(Ease.progress(t, 5.0, 5.6))
        let cut = Ease.progress(t, 1.3, 1.6)
        let cloudDim = Ease.inOut(Ease.progress(t, 1.4, 1.9)) * (1 - reset)
        let cx: CGFloat = 130
        let cloudBottom: CGFloat = 60, phoneTop: CGFloat = 104, mid: CGFloat = 82

        // A server, not a cloud: nothing goes to anyone's server, while
        // backups (locked) may go to the person's own iCloud.
        let server = Color.white.opacity(0.75 - 0.5 * cloudDim)
        for row in 0..<3 {
            let r = CGRect(x: cx - 30, y: 14 + CGFloat(row) * 15, width: 60, height: 12)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(server), lineWidth: 1.6)
            ctx.fill(Path(ellipseIn: CGRect(x: r.maxX - 10, y: r.midY - 1.5, width: 3, height: 3)), with: .color(server))
        }

        // The line rises from the phone to the cloud, then is cut.
        let draw = Ease.inOut(Ease.progress(t, 0.2, 0.65))
        var line = ctx
        line.opacity = 1 - reset
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4])
        if t < 1.3 {
            var p = Path()
            p.move(to: CGPoint(x: cx, y: phoneTop - 2))
            p.addLine(to: CGPoint(x: cx, y: phoneTop - 2 - (phoneTop - 2 - cloudBottom) * CGFloat(draw)))
            line.stroke(p, with: .color(.white.opacity(0.5)), style: style)
        } else {
            let gap = CGFloat(10 * Ease.settle(cut))
            var top = Path()
            top.move(to: CGPoint(x: cx, y: cloudBottom))
            top.addLine(to: CGPoint(x: cx, y: mid - gap))
            var bottom = Path()
            bottom.move(to: CGPoint(x: cx, y: mid + gap))
            bottom.addLine(to: CGPoint(x: cx, y: phoneTop - 2))
            line.stroke(top, with: .color(.white.opacity(0.5 - 0.3 * cloudDim)), style: style)
            line.stroke(bottom, with: .color(.white.opacity(0.5)), style: style)
            // The cut mark.
            let mark = CGFloat(Ease.out(Ease.progress(t, 1.32, 1.55)))
            var x = Path()
            x.move(to: CGPoint(x: cx - 5, y: mid - 5)); x.addLine(to: CGPoint(x: cx + 5, y: mid + 5))
            x.move(to: CGPoint(x: cx + 5, y: mid - 5)); x.addLine(to: CGPoint(x: cx - 5, y: mid + 5))
            line.stroke(x.trimmedPath(from: 0, to: mark), with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }

        // What was on its way out comes back down.
        let rises: [CGFloat] = [20, 13, 7]
        for (k, rise) in rises.enumerated() {
            let start = 0.62 + Double(k) * 0.14
            guard t > start else { continue }
            var y: CGFloat
            if t < 1.3 {
                y = phoneTop - 6 - rise * CGFloat(Ease.out(Ease.progress(t, start, 1.3)))
            } else {
                let fall = Ease.in(Ease.progress(t, 1.32 + Double(k) * 0.05, 1.75 + Double(k) * 0.05))
                y = phoneTop - 6 - rise + (rise + 4) * CGFloat(fall)
                if fall >= 1 { continue }
            }
            ctx.fill(rounded: CGRect(x: cx - 3, y: y - 3, width: 6, height: 6), radius: 1.6, .white.opacity(0.85))
        }

        let screen = Parts.phone(ctx, CGRect(x: 88, y: phoneTop, width: 84, height: 140), radius: 18, island: false)
        let grid = CGRect(x: screen.minX + 6, y: screen.minY + 12, width: screen.width - 12, height: screen.height - 24)
        let w = (grid.width - 5) / 2, h = (grid.height - 10) / 3
        for i in 0..<6 {
            let beat = 2.0 + 0.15 * Double(i / 2)
            let bump = CGFloat(Ease.pulse(Ease.progress(t, beat, beat + 0.3))) * (i.isMultiple(of: 2) ? 1 : 0.6)
            let tile = CGRect(x: grid.minX + CGFloat(i % 2) * (w + 5), y: grid.minY + CGFloat(i / 2) * (h + 5), width: w, height: h)
            ctx.fill(rounded: GraphicsContext.scaled(tile, 1 + 0.08 * bump), radius: 6, .white.opacity(Self.shades[i] + 0.12 * Double(bump)))
        }
    }
}
