import SwiftUI

/// Casita's own line glyphs, drawn on a 24-unit grid with round caps, so
/// spaces never look like an iOS home screen of SF Symbols.
enum Glyph: String, CaseIterable, Sendable {
    case photos, camera, files, web, spaces, settings, lock, shield, key, cloud, house, incognito

    /// The glyph's strokes in 24-unit space.
    fileprivate func path() -> Path {
        var p = Path()
        switch self {
        case .photos:
            p.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 16), cornerSize: CGSize(width: 3.5, height: 3.5), style: .continuous)
            p.move(to: CGPoint(x: 3.6, y: 17.2))
            p.addLine(to: CGPoint(x: 9, y: 11.8))
            p.addLine(to: CGPoint(x: 13, y: 15.6))
            p.addLine(to: CGPoint(x: 15.4, y: 13.2))
            p.addLine(to: CGPoint(x: 20.4, y: 18))
            p.addEllipse(in: CGRect(x: 14.4, y: 7, width: 3.2, height: 3.2))
        case .camera:
            p.addRoundedRect(in: CGRect(x: 2.5, y: 7, width: 19, height: 13), cornerSize: CGSize(width: 3.8, height: 3.8), style: .continuous)
            p.move(to: CGPoint(x: 8, y: 7))
            p.addLine(to: CGPoint(x: 9.3, y: 4.9))
            p.addQuadCurve(to: CGPoint(x: 10.3, y: 4.4), control: CGPoint(x: 9.6, y: 4.4))
            p.addLine(to: CGPoint(x: 13.7, y: 4.4))
            p.addQuadCurve(to: CGPoint(x: 14.7, y: 4.9), control: CGPoint(x: 14.4, y: 4.4))
            p.addLine(to: CGPoint(x: 16, y: 7))
            p.addEllipse(in: CGRect(x: 8.3, y: 9.7, width: 7.4, height: 7.4))
        case .files:
            p.move(to: CGPoint(x: 7.2, y: 3))
            p.addLine(to: CGPoint(x: 13.6, y: 3))
            p.addLine(to: CGPoint(x: 19, y: 8.4))
            p.addLine(to: CGPoint(x: 19, y: 18.8))
            p.addQuadCurve(to: CGPoint(x: 16.8, y: 21), control: CGPoint(x: 19, y: 21))
            p.addLine(to: CGPoint(x: 7.2, y: 21))
            p.addQuadCurve(to: CGPoint(x: 5, y: 18.8), control: CGPoint(x: 5, y: 21))
            p.addLine(to: CGPoint(x: 5, y: 5.2))
            p.addQuadCurve(to: CGPoint(x: 7.2, y: 3), control: CGPoint(x: 5, y: 3))
            p.closeSubpath()
            p.move(to: CGPoint(x: 13.6, y: 3))
            p.addLine(to: CGPoint(x: 13.6, y: 7))
            p.addQuadCurve(to: CGPoint(x: 15, y: 8.4), control: CGPoint(x: 13.6, y: 8.4))
            p.addLine(to: CGPoint(x: 19, y: 8.4))
            p.move(to: CGPoint(x: 8.6, y: 13.2))
            p.addLine(to: CGPoint(x: 15.4, y: 13.2))
            p.move(to: CGPoint(x: 8.6, y: 16.8))
            p.addLine(to: CGPoint(x: 13, y: 16.8))
        case .web:
            p.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            p.addEllipse(in: CGRect(x: 8.2, y: 3, width: 7.6, height: 18))
            p.move(to: CGPoint(x: 3.3, y: 12))
            p.addLine(to: CGPoint(x: 20.7, y: 12))
        case .spaces:
            // Two houses, one behind the other: a space and the spaces under it.
            p.move(to: CGPoint(x: 12.6, y: 6.4))
            p.addLine(to: CGPoint(x: 15, y: 4.4))
            p.addLine(to: CGPoint(x: 21, y: 9.4))
            p.addLine(to: CGPoint(x: 21, y: 16.6))
            p.addQuadCurve(to: CGPoint(x: 19.8, y: 17.8), control: CGPoint(x: 21, y: 17.8))
            p.addLine(to: CGPoint(x: 18, y: 17.8))
            p.move(to: CGPoint(x: 3, y: 12.6))
            p.addLine(to: CGPoint(x: 9.5, y: 7.2))
            p.addLine(to: CGPoint(x: 16, y: 12.6))
            p.addLine(to: CGPoint(x: 16, y: 19.6))
            p.addQuadCurve(to: CGPoint(x: 14.6, y: 21), control: CGPoint(x: 16, y: 21))
            p.addLine(to: CGPoint(x: 4.4, y: 21))
            p.addQuadCurve(to: CGPoint(x: 3, y: 19.6), control: CGPoint(x: 3, y: 21))
            p.closeSubpath()
        case .settings:
            p.move(to: CGPoint(x: 3.5, y: 7.5)); p.addLine(to: CGPoint(x: 6.4, y: 7.5))
            p.move(to: CGPoint(x: 11.6, y: 7.5)); p.addLine(to: CGPoint(x: 20.5, y: 7.5))
            p.addEllipse(in: CGRect(x: 6.4, y: 4.9, width: 5.2, height: 5.2))
            p.move(to: CGPoint(x: 3.5, y: 16.5)); p.addLine(to: CGPoint(x: 12.4, y: 16.5))
            p.move(to: CGPoint(x: 17.6, y: 16.5)); p.addLine(to: CGPoint(x: 20.5, y: 16.5))
            p.addEllipse(in: CGRect(x: 12.4, y: 13.9, width: 5.2, height: 5.2))
        case .lock:
            p.addRoundedRect(in: CGRect(x: 5, y: 10.5, width: 14, height: 10.5), cornerSize: CGSize(width: 3.2, height: 3.2), style: .continuous)
            p.move(to: CGPoint(x: 8.2, y: 10.5))
            p.addLine(to: CGPoint(x: 8.2, y: 8))
            p.addQuadCurve(to: CGPoint(x: 12, y: 4), control: CGPoint(x: 8.2, y: 4))
            p.addQuadCurve(to: CGPoint(x: 15.8, y: 8), control: CGPoint(x: 15.8, y: 4))
            p.addLine(to: CGPoint(x: 15.8, y: 10.5))
            p.move(to: CGPoint(x: 12, y: 14.6)); p.addLine(to: CGPoint(x: 12, y: 16.8))
        case .shield:
            p.move(to: CGPoint(x: 12, y: 3))
            p.addLine(to: CGPoint(x: 19, y: 6))
            p.addLine(to: CGPoint(x: 19, y: 11.4))
            p.addQuadCurve(to: CGPoint(x: 12, y: 21), control: CGPoint(x: 19, y: 17.6))
            p.addQuadCurve(to: CGPoint(x: 5, y: 11.4), control: CGPoint(x: 5, y: 17.6))
            p.addLine(to: CGPoint(x: 5, y: 6))
            p.closeSubpath()
            p.move(to: CGPoint(x: 9, y: 12.2))
            p.addLine(to: CGPoint(x: 11.2, y: 14.4))
            p.addLine(to: CGPoint(x: 15.2, y: 10.2))
        case .key:
            p.addEllipse(in: CGRect(x: 3.5, y: 8, width: 8, height: 8))
            p.move(to: CGPoint(x: 11.5, y: 12)); p.addLine(to: CGPoint(x: 20.5, y: 12))
            p.move(to: CGPoint(x: 17.2, y: 12)); p.addLine(to: CGPoint(x: 17.2, y: 15))
            p.move(to: CGPoint(x: 20.5, y: 12)); p.addLine(to: CGPoint(x: 20.5, y: 14.4))
        case .cloud:
            p.move(to: CGPoint(x: 7.4, y: 18.6))
            p.addLine(to: CGPoint(x: 17, y: 18.6))
            p.addQuadCurve(to: CGPoint(x: 21, y: 14.7), control: CGPoint(x: 21, y: 18.6))
            p.addQuadCurve(to: CGPoint(x: 17.4, y: 11), control: CGPoint(x: 21, y: 11.2))
            p.addQuadCurve(to: CGPoint(x: 12, y: 6.4), control: CGPoint(x: 16.6, y: 6.4))
            p.addQuadCurve(to: CGPoint(x: 7.2, y: 10.2), control: CGPoint(x: 8.2, y: 6.4))
            p.addQuadCurve(to: CGPoint(x: 3, y: 14.5), control: CGPoint(x: 3, y: 10.6))
            p.addQuadCurve(to: CGPoint(x: 7.4, y: 18.6), control: CGPoint(x: 3, y: 18.6))
            p.closeSubpath()
        case .house:
            p.move(to: CGPoint(x: 4, y: 11))
            p.addLine(to: CGPoint(x: 12, y: 4.4))
            p.addLine(to: CGPoint(x: 20, y: 11))
            p.addLine(to: CGPoint(x: 20, y: 19))
            p.addQuadCurve(to: CGPoint(x: 18.4, y: 20.6), control: CGPoint(x: 20, y: 20.6))
            p.addLine(to: CGPoint(x: 5.6, y: 20.6))
            p.addQuadCurve(to: CGPoint(x: 4, y: 19), control: CGPoint(x: 4, y: 20.6))
            p.closeSubpath()
        case .incognito:
            // A hat over round glasses: a browser that remembers nobody.
            p.move(to: CGPoint(x: 3, y: 10)); p.addLine(to: CGPoint(x: 21, y: 10))
            p.move(to: CGPoint(x: 6.4, y: 10))
            p.addLine(to: CGPoint(x: 8.2, y: 4.9))
            p.addQuadCurve(to: CGPoint(x: 12, y: 5.6), control: CGPoint(x: 10, y: 4.4))
            p.addQuadCurve(to: CGPoint(x: 15.8, y: 4.9), control: CGPoint(x: 14, y: 4.4))
            p.addLine(to: CGPoint(x: 17.6, y: 10))
            p.addEllipse(in: CGRect(x: 4.4, y: 13.4, width: 6, height: 6))
            p.addEllipse(in: CGRect(x: 13.6, y: 13.4, width: 6, height: 6))
            p.move(to: CGPoint(x: 10.4, y: 16.2))
            p.addQuadCurve(to: CGPoint(x: 13.6, y: 16.2), control: CGPoint(x: 12, y: 15))
        }
        return p
    }
}

/// A glyph stroked at any size; the line keeps its weight relative to size.
struct GlyphView: View {
    var glyph: Glyph
    /// Stroke width at 24 points.
    var lineWidth: CGFloat = 1.8

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let path = glyph.path().applying(CGAffineTransform(scaleX: scale, y: scale)
                .translatedBy(x: (size.width / scale - 24) / 2, y: (size.height / scale - 24) / 2))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
