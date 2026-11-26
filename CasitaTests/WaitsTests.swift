import Foundation
import Testing
@testable import Casita

@Suite(.serialized) struct WaitsTests {
    @Test func fiveWrongCodesStartAOneMinuteWait() {
        let waits = WrongCodeWaits()
        waits.reset()
        defer { waits.reset() }
        for _ in 0..<4 { waits.registerWrongAttempt() }
        #expect(!waits.isWaiting)
        waits.registerWrongAttempt()
        let left = (waits.waitUntil ?? .distantPast).timeIntervalSinceNow
        #expect(left > 55 && left <= 60)
        waits.reset()
        #expect(!waits.isWaiting)
    }

    /// One wrong try falls away per hour without another; nothing else
    /// lowers the count.
    @Test func theCountFallsByOneAnHour() {
        #expect(WrongCodeWaits.fallen(4, after: 3599).count == 4)
        #expect(WrongCodeWaits.fallen(4, after: 7300) == (2, 7200))
        #expect(WrongCodeWaits.fallen(2, after: 86_400) == (0, 7200))
        #expect(WrongCodeWaits.fallen(3, after: -5).count == 3)
    }
}
