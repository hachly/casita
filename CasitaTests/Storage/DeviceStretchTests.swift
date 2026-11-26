import CryptoKit
import Foundation
import Testing
@testable import Casita

/// Runs only on a real iPhone: how long one guess takes through the Secure
/// Enclave (the code check's main cost). The target is about 0.5–1 s
/// per try on the slowest supported iPhone; this records the number.
@Suite struct DeviceStretchTests {
    /// The simulator on Apple silicon emulates a (much faster) Secure Enclave, so real iPhones only.
    @Test(.enabled(if: SecureEnclave.isAvailable && ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil))
    func oneGuessTakesAboutASecond() throws {
        let stretcher = SecureEnclaveStretcher(rounds: SecureEnclaveStretcher.defaultRounds, iterations: 600_000)
        let salt = ReservedStorage.randomBytes(32)
        let clock = ContinuousClock()
        let first = try clock.measure { _ = try stretcher.stretch(code: "123456", salt: salt) }
        let second = try clock.measure { _ = try stretcher.stretch(code: "999999", salt: salt) }
        let rounds = try SecureEnclaveStretcher.calibratedRounds()
        print("CASITA-DEVICE stretch right=\(first) wrong=\(second) calibratedRounds(500ms)=\(rounds) defaultRounds=\(SecureEnclaveStretcher.defaultRounds)")
        #expect(second > .milliseconds(200), "A guess is too cheap to slow anyone down: \(second)")
        #expect(second < .seconds(3), "A guess is too slow for everyday use: \(second)")
    }
}
