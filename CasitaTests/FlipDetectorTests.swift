import Foundation
import Testing
@testable import Casita

@Suite struct FlipDetectorTests {
    private func run(_ samples: Int, faceDown: Double, shake: Double, turn: Double, touchedAgo: TimeInterval) -> Bool {
        var detector = FlipDetector()
        let start = Date(timeIntervalSince1970: 1_000)
        var locked = false
        for i in 0..<samples {
            let now = start.addingTimeInterval(Double(i) * 0.1)
            // `touchedAgo` before every sample: someone still scrolling.
            locked = detector.sample(faceDown: faceDown, shake: shake, turn: turn, at: now, lastTouch: now.addingTimeInterval(-touchedAgo))
            if locked { break }
        }
        return locked
    }

    @Test func putDownOnATableLocksAfterASecond() {
        #expect(run(12, faceDown: 0.99, shake: 0.004, turn: 0.01, touchedAgo: 3))
        #expect(!run(9, faceDown: 0.99, shake: 0.004, turn: 0.01, touchedAgo: 3))
    }

    @Test func heldOverheadInBedNeverLocks() {
        // Screen down, but a hand trembles and turns, and keeps scrolling.
        #expect(!run(100, faceDown: 0.93, shake: 0.05, turn: 0.3, touchedAgo: 3))
        #expect(!run(100, faceDown: 0.99, shake: 0.004, turn: 0.01, touchedAgo: 0.5))
        #expect(!run(100, faceDown: 0.99, shake: 0.02, turn: 0.25, touchedAgo: 5))
    }

    @Test func anyMovementStartsTheSecondAgain() {
        var detector = FlipDetector()
        let t0 = Date(timeIntervalSince1970: 1_000), touch = t0.addingTimeInterval(-5)
        for i in 0..<8 { _ = detector.sample(faceDown: 0.99, shake: 0.004, turn: 0.01, at: t0.addingTimeInterval(Double(i) * 0.1), lastTouch: touch) }
        _ = detector.sample(faceDown: 0.99, shake: 0.2, turn: 0.01, at: t0.addingTimeInterval(0.8), lastTouch: touch)
        let locked = detector.sample(faceDown: 0.99, shake: 0.004, turn: 0.01, at: t0.addingTimeInterval(1.2), lastTouch: touch)
        #expect(!locked)
    }
}
