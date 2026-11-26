import XCTest

/// A new install from the first screen to the first space: logo intro,
/// welcome pages, both codes, the demo, storage, the recovery sentence, backup,
/// the closing steps and the hard paywall (a RevenueCat Test Store
/// purchase), then the everyday space opens with no code asked again.
final class OnboardingE2ETests: XCTestCase {
    static let everyday = "111111"
    static let top = "222222"

    @MainActor func testClosingPaywallFinishesSetupOnFree() {
        let app = E2E.launch()
        E2E.wait(app, "onboarding.welcome", timeout: 15)
        E2E.snap(app, "logo intro", in: self)
        sleep(3)
        E2E.snap(app, "welcome", in: self)

        // Welcome pages until the everyday code.
        var page = 0
        while !E2E.element(app, "onboarding.code.everyday.intro").exists, page < 6 {
            E2E.tap(app, "onboarding.next")
            page += 1
            sleep(1)
            E2E.snap(app, "welcome page \(page)", in: self)
        }

        setCode(app, Self.everyday, step: "everyday")
        setCode(app, Self.top, step: "private")

        // The private code's Continue sets 512 MB aside: no page of its own.
        XCTAssertFalse(E2E.element(app, "onboarding.storage").exists, "No storage page")
        E2E.snap(app, "setting up", in: self)

        // The recovery sentence leads straight on: no backup or reset
        // switches here. "I saved it" asks once more.
        E2E.wait(app, "onboarding.recovery.words", timeout: 240)
        sleep(1)
        E2E.snap(app, "recovery sentence appearing", in: self)
        sleep(2)
        E2E.snap(app, "recovery sentence", in: self)
        E2E.confirmSaved(app, snapIn: self)

        // Fill: the house takes things in; one switch shows the ways to add.
        E2E.wait(app, "onboarding.fill", timeout: 30)
        XCTAssertFalse(E2E.element(app, "onboarding.fill.photos").exists, "Nothing to add until the switch is on")
        sleep(3)
        E2E.snap(app, "fill", in: self)
        E2E.tap(app, "onboarding.fill.toggle")
        E2E.wait(app, "onboarding.fill.photos")
        XCTAssertTrue(E2E.element(app, "onboarding.fill.files").exists)
        XCTAssertTrue(E2E.element(app, "onboarding.fill.web").exists)
        sleep(1)
        E2E.snap(app, "fill on", in: self)
        E2E.tap(app, "onboarding.continue")

        // No rating request in setup (guideline 5.6.3): straight to the paywall.
        XCTAssertFalse(app.buttons["Not Now"].exists, "No rating prompt during setup")

        // The offer keeps its two pages, with a usable X on both.
        E2E.wait(app, "paywall.intro.continue", timeout: 30)
        XCTAssertTrue(E2E.element(app, "paywall.close").exists, "Onboarding always has a close button")
        sleep(4) // the house acts out the two codes
        E2E.snap(app, "paywall trial", in: self)
        E2E.tap(app, "paywall.intro.continue")
        E2E.waitForPlans(app, timeout: 30)
        XCTAssertTrue(E2E.element(app, "paywall.close").exists, "Onboarding always has a close button")
        sleep(1)
        E2E.snap(app, "paywall plans", in: self)
        XCTAssertFalse(app.buttons["Continue with Free"].exists)
        E2E.tap(app, "paywall.close")

        // Setup ends in the everyday space, no code asked again. Above
        // Lock, one note at a time: backups, the reset switch, then the
        // Open-faster tip. Each goes once closed.
        E2E.wait(app, "space.screen", timeout: 30)
        XCTAssertFalse(E2E.element(app, "entry.screen").exists, "No code screen after setup")
        for note in ["space.askBackup", "space.askReset", "space.tip"] {
            E2E.wait(app, note, timeout: 10)
            sleep(1)
            E2E.snap(app, "first space: \(note)", in: self)
            E2E.tap(app, "\(note).close")
            XCTAssertTrue(E2E.element(app, note).waitForNonExistence(timeout: 3), "\(note) closes")
        }
        E2E.snap(app, "first space", in: self)
    }

    /// Types the code, then the same code again, then continues.
    @MainActor private func setCode(_ app: XCUIApplication, _ code: String, step: String) {
        E2E.wait(app, "onboarding.code.\(step).intro")
        sleep(3)
        E2E.snap(app, "\(step) intro", in: self)
        E2E.tap(app, "onboarding.continue")
        E2E.wait(app, "onboarding.code.\(step)")
        sleep(1)
        E2E.snap(app, "\(step) code", in: self)
        E2E.type(app, code)
        sleep(1)
        E2E.snap(app, "\(step) code again", in: self)
        E2E.type(app, code)
        E2E.wait(app, "onboarding.code.\(step).set", timeout: 15)
        sleep(1)
        E2E.snap(app, "\(step) code set", in: self)
        E2E.tap(app, "onboarding.continue")
    }
}
