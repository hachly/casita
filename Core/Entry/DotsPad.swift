import SwiftUI

/// How a drawn path becomes a code. 3×3 keeps the original "dots:0-4-8"
/// form, so codes set before grid sizes existed still open. Other sizes
/// name their grid ("dots5:0-6-12"), so the same path on another grid is a
/// different code. Nothing stores which size a space uses: the entry
/// screen always starts on 3×3 and the person picks the size each time.
enum DotsCode {
    static let sizes = [3, 4, 5, 6]

    static func make(_ path: [Int], gridSize: Int) -> String {
        (gridSize == 3 ? "dots:" : "dots\(gridSize):") + path.map(String.init).joined(separator: "-")
    }

    /// How many dots a dots code joins; nil when it isn't one.
    static func dotCount(_ code: String) -> Int? {
        guard code.hasPrefix("dots"), let colon = code.firstIndex(of: ":") else { return nil }
        return code[code.index(after: colon)...].split(separator: "-").count
    }
}

/// A square grid of dots; the code is the path drawn through it, handed
/// over as a `DotsCode` when the finger lifts. Each dot is a ring; a joined
/// dot fills with a little pop. The line between joined dots is white at
/// partial strength, and `hideLine` leaves it out entirely.
struct DotsPad: View {
    var gridSize = 3
    var hideLine: Bool
    var haptics = true
    /// Shorter paths are dropped without submitting.
    var minimumDots = 2
    var onSubmit: (String) -> Void

    @State private var path: [Int] = []
    @State private var finger: CGPoint?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 280
    private var count: Int { gridSize * gridSize }
    private var step: CGFloat { size / CGFloat(gridSize) }
    /// The ring's radius: 16 points on 3×3, smaller on bigger grids.
    private var ring: CGFloat { min(16, step * 0.2) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !hideLine {
                Canvas { context, _ in
                    guard let first = path.first else { return }
                    var line = Path()
                    line.move(to: center(first))
                    for i in path.dropFirst() { line.addLine(to: center(i)) }
                    if let finger { line.addLine(to: finger) }
                    context.stroke(line, with: .color(.white.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: max(3, ring * 0.32), lineCap: .round, lineJoin: .round))
                }
                .allowsHitTesting(false)
            }
            ForEach(0..<count, id: \.self) { i in
                DotMark(joined: path.contains(i), radius: ring, reduceMotion: reduceMotion)
                    .position(center(i))
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isEnabled else { return }
                    finger = value.location
                    if let hit = (0..<count).first(where: { center($0).distance(to: value.location) < step * 0.38 }), !path.contains(hit) {
                        path.append(hit)
                        if haptics { Haptics.play(.tap) }
                    }
                }
                .onEnded { _ in
                    let drawn = path
                    path = []
                    finger = nil
                    guard isEnabled else { return }
                    if drawn.count >= minimumDots { onSubmit(DotsCode.make(drawn, gridSize: gridSize)) }
                }
        )
        .id(gridSize)
        .accessibilityElement()
        .accessibilityLabel("\(gridSize) by \(gridSize) dots")
        .accessibilityIdentifier("entry.dots.pad")
    }

    private func center(_ i: Int) -> CGPoint {
        CGPoint(x: step * (CGFloat(i % gridSize) + 0.5), y: step * (CGFloat(i / gridSize) + 0.5))
    }
}

/// One dot: a quiet ring with a speck in the middle; joined, the ring
/// brightens and the middle fills with a springy pop.
private struct DotMark: View {
    var joined: Bool
    var radius: CGFloat
    var reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(joined ? 0.85 : 0.32), lineWidth: max(1.5, radius * 0.12))
                .scaleEffect(joined ? 1.1 : 1)
            Circle()
                .fill(Color.white)
                .frame(width: radius * 1.05, height: radius * 1.05)
                .scaleEffect(joined ? 1 : 0.3)
                .opacity(joined ? 1 : 0.45)
        }
        .frame(width: radius * 2, height: radius * 2)
        .animation(joined && !reduceMotion ? .spring(response: 0.28, dampingFraction: 0.42) : .smooth(duration: 0.22), value: joined)
    }
}

/// The grid size switch under the dots: 3×3 up to 6×6. The same sliding
/// capsule as the unlock method switch, in a smaller size.
struct DotsGridPicker: View {
    @Binding var size: Int
    var haptics = true

    var body: some View {
        EntrySegments(options: DotsCode.sizes, selection: $size, compact: true, haptics: haptics,
                      title: { "\($0)×\($0)" }, identifier: { "entry.dots.size.\($0)" })
    }
}

/// A row of choices with one capsule that slides to the chosen one. Plain
/// SwiftUI buttons, so it works where UIKit-backed segmented pickers don't.
/// The full size has a white capsule with black text; `compact` has a grey
/// capsule with white text, for a secondary choice under the main one.
struct EntrySegments<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    var compact = false
    var haptics = true
    var title: (Value) -> String
    var identifier: (Value) -> String
    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    guard !selected else { return }
                    if haptics { Haptics.play(.select) }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(compact ? .footnote.weight(.semibold).monospacedDigit() : .subheadline.weight(.semibold))
                        .foregroundStyle(selected ? (compact ? Theme.primary : Color.black) : Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 38)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(compact ? Theme.raised : Color.white)
                                    .matchedGeometryEffect(id: "selection", in: capsule)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier(option))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(compact ? 3 : 4)
        .background(Capsule().fill(compact ? Color.clear : Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .frame(maxWidth: compact ? 232 : 280)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
