import SwiftUI

/// Line art for onboarding scenes, on the same 24-unit grid as Casita's
/// glyphs so a scene's key or cloud matches the glyph of the same name.
/// Scenes draw these in a Canvas so parts can move, trim and fade.
enum Art {
    static func key() -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 3.5, y: 8, width: 8, height: 8))
        p.move(to: CGPoint(x: 11.5, y: 12)); p.addLine(to: CGPoint(x: 20.5, y: 12))
        p.move(to: CGPoint(x: 17.2, y: 12)); p.addLine(to: CGPoint(x: 17.2, y: 15))
        p.move(to: CGPoint(x: 20.5, y: 12)); p.addLine(to: CGPoint(x: 20.5, y: 14.4))
        return p
    }

    static func cloud() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 7.4, y: 18.6))
        p.addLine(to: CGPoint(x: 17, y: 18.6))
        p.addQuadCurve(to: CGPoint(x: 21, y: 14.7), control: CGPoint(x: 21, y: 18.6))
        p.addQuadCurve(to: CGPoint(x: 17.4, y: 11), control: CGPoint(x: 21, y: 11.2))
        p.addQuadCurve(to: CGPoint(x: 12, y: 6.4), control: CGPoint(x: 16.6, y: 6.4))
        p.addQuadCurve(to: CGPoint(x: 7.2, y: 10.2), control: CGPoint(x: 8.2, y: 6.4))
        p.addQuadCurve(to: CGPoint(x: 3, y: 14.5), control: CGPoint(x: 3, y: 10.6))
        p.addQuadCurve(to: CGPoint(x: 7.4, y: 18.6), control: CGPoint(x: 3, y: 18.6))
        p.closeSubpath()
        return p
    }

    /// The shield's outline, starting at its top point.
    static func shield() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 3))
        p.addLine(to: CGPoint(x: 19, y: 6))
        p.addLine(to: CGPoint(x: 19, y: 11.4))
        p.addQuadCurve(to: CGPoint(x: 12, y: 21), control: CGPoint(x: 19, y: 17.6))
        p.addQuadCurve(to: CGPoint(x: 5, y: 11.4), control: CGPoint(x: 5, y: 17.6))
        p.addLine(to: CGPoint(x: 5, y: 6))
        p.closeSubpath()
        return p
    }

    static func check() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 7, y: 12.4))
        p.addLine(to: CGPoint(x: 10.4, y: 15.6))
        p.addLine(to: CGPoint(x: 17, y: 8.8))
        return p
    }

    static func house() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 4, y: 11))
        p.addLine(to: CGPoint(x: 12, y: 4.4))
        p.addLine(to: CGPoint(x: 20, y: 11))
        p.addLine(to: CGPoint(x: 20, y: 19))
        p.addQuadCurve(to: CGPoint(x: 18.4, y: 20.6), control: CGPoint(x: 20, y: 20.6))
        p.addLine(to: CGPoint(x: 5.6, y: 20.6))
        p.addQuadCurve(to: CGPoint(x: 4, y: 19), control: CGPoint(x: 4, y: 20.6))
        p.closeSubpath()
        return p
    }

    static func globe() -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
        p.addEllipse(in: CGRect(x: 8.2, y: 3, width: 7.6, height: 18))
        p.move(to: CGPoint(x: 3.3, y: 12))
        p.addLine(to: CGPoint(x: 20.7, y: 12))
        return p
    }

    static func photo() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 16), cornerSize: CGSize(width: 3.5, height: 3.5), style: .continuous)
        p.move(to: CGPoint(x: 3.6, y: 17.2))
        p.addLine(to: CGPoint(x: 9, y: 11.8))
        p.addLine(to: CGPoint(x: 13, y: 15.6))
        p.addLine(to: CGPoint(x: 15.4, y: 13.2))
        p.addLine(to: CGPoint(x: 20.4, y: 18))
        p.addEllipse(in: CGRect(x: 14.4, y: 7, width: 3.2, height: 3.2))
        return p
    }

    /// A five-point star, filled.
    static func star() -> Path {
        var p = Path()
        let center = CGPoint(x: 12, y: 12.6)
        for i in 0..<10 {
            let r: CGFloat = i.isMultiple(of: 2) ? 9.6 : 4.1
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        return p
    }

    /// `path` from the 24-unit grid, `size` points wide, centred on `center`.
    static func place(_ path: Path, center: CGPoint, size: CGFloat) -> Path {
        let s = size / 24
        return path.applying(CGAffineTransform(translationX: center.x - 12 * s, y: center.y - 12 * s).scaledBy(x: s, y: s))
    }
}

extension GraphicsContext {
    /// Strokes grid art at `center`, `size` points wide, with the glyph line weight.
    func stroke(art: Path, center: CGPoint, size: CGFloat, color: Color, weight: CGFloat = 1.8, trim: CGFloat = 1) {
        guard trim > 0.001 else { return }
        var path = Art.place(art, center: center, size: size)
        if trim < 0.999 { path = path.trimmedPath(from: 0, to: trim) }
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: weight * size / 24, lineCap: .round, lineJoin: .round))
    }

    func fill(rounded rect: CGRect, radius: CGFloat, _ color: Color) {
        fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(color))
    }

    func fill(circle center: CGPoint, radius: CGFloat, _ color: Color) {
        guard radius > 0.05 else { return }
        fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)), with: .color(color))
    }

    func stroke(circle center: CGPoint, radius: CGFloat, _ color: Color, width: CGFloat, trim: CGFloat = 1) {
        guard radius > 0.05, trim > 0.001 else { return }
        // Starts at 12 o'clock and runs clockwise.
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * Double(trim)), clockwise: false)
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// The same box, scaled by `scale` around its centre.
    static func scaled(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
        rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
    }
}

/// Small pieces several scenes share.
enum Parts {
    /// A phone outline with its screen; returns the screen's rectangle.
    @discardableResult
    static func phone(_ ctx: GraphicsContext, _ rect: CGRect, radius: CGFloat, island: Bool = true, line: Color = Color.white.opacity(0.24)) -> CGRect {
        ctx.fill(rounded: rect, radius: radius, Theme.surface)
        ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius, style: .continuous), with: .color(line), lineWidth: 1.5)
        let inset = max(3, rect.width * 0.04)
        let screen = rect.insetBy(dx: inset, dy: inset)
        ctx.fill(rounded: screen, radius: radius - inset, .black)
        if island {
            let w = rect.width * 0.28, h = max(4, rect.width * 0.075)
            ctx.fill(rounded: CGRect(x: rect.midX - w / 2, y: screen.minY + h * 0.9, width: w, height: h), radius: h / 2, Theme.raised)
        }
        return screen
    }

    /// The entry screen in miniature: the code's dots and the number pad.
    /// `filled` dots are set; `pops` gives each dot's pop-in (0...1);
    /// `press` gives each of the 12 keys' press (0...1).
    static func entry(_ ctx: GraphicsContext, in screen: CGRect, filled: Int, pops: [Double] = [], press: [Double] = []) {
        let unit = screen.width / 112
        let dotY = screen.minY + screen.height * 0.24
        for i in 0..<6 {
            let x = screen.midX + (CGFloat(i) - 2.5) * 11 * unit
            let on = i < filled
            let pop = i < pops.count ? pops[i] : 1
            let r = on ? 3 * unit * CGFloat(0.6 + 0.4 * Ease.settle(pop)) : 2.4 * unit
            ctx.fill(circle: CGPoint(x: x, y: dotY), radius: r, on ? .white : Color.white.opacity(0.26))
        }
        let top = screen.minY + screen.height * 0.43
        let step = 28 * unit
        for key in 0..<12 {
            let col = CGFloat(key % 3) - 1, row = CGFloat(key / 3)
            let center = CGPoint(x: screen.midX + col * step, y: top + row * step)
            let p = key < press.count ? press[key] : 0
            let r = 9.5 * unit * CGFloat(1 - 0.18 * p)
            ctx.fill(circle: center, radius: r, key == 11 ? Color.white.opacity(0.9) : Color.white.opacity(0.12 + 0.4 * p))
        }
    }

    /// A grid of soft grey photo tiles. `appear(i)` gives tile i's arrival (0...1).
    static func photos(_ ctx: GraphicsContext, in rect: CGRect, columns: Int, rows: Int, gap: CGFloat, radius: CGFloat,
                       shades: [Double], appear: (Int) -> Double) {
        let w = (rect.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let h = (rect.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for i in 0..<(columns * rows) {
            let a = appear(i)
            guard a > 0.001 else { continue }
            let tile = CGRect(x: rect.minX + CGFloat(i % columns) * (w + gap), y: rect.minY + CGFloat(i / columns) * (h + gap), width: w, height: h)
            var c = ctx
            c.opacity = min(1, a * 1.6)
            c.fill(rounded: GraphicsContext.scaled(tile, CGFloat(0.55 + 0.45 * Ease.settle(a))), radius: radius, Color.white.opacity(shades[i % shades.count]))
        }
    }
}
