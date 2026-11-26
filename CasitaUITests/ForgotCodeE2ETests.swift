import XCTest

/// "Forgot code?" on the entry screen, the reminder that asks now and then,
/// and both ways out: new code from the recovery sentence, or erase and start over.
final class ForgotCodeE2ETests: XCTestCase {
    @MainActor func testReminderThenResetWithWords() {
        let app = E2E.launch(["-devCodes", "111111,222222", "-devRecoveryWords", "-devResetSwitch", "-devStaleCode"])
        E2E.wait(app, "entry.screen", timeout: 30)
        let message = E2E.element(app, "entry.message")
        XCTAssertTrue(message.label.lowercased().contains("remember"), "The reminder should show after a month: \(message.label)")
        E2E.snap(app, "reminder", in: self)

        E2E.tap(app, "entry.forgot")
        E2E.wait(app, "forgot.choose")
        E2E.snap(app, "forgot code", in: self)
        E2E.tap(app, "forgot.words")
        let phrase = E2E.wait(app, "forgot.phrase")
        phrase.tap()
        phrase.typeText(E2E.devPhrase)
        E2E.snap(app, "sentence typed", in: self)
        E2E.tap(app, "forgot.next")
        for step in ["new code", "new code again"] {
            let field = E2E.wait(app, "code.field")
            field.tap()
            field.typeText("333333")
            E2E.snap(app, step, in: self)
            E2E.tap(app, "code.submit")
        }
        E2E.wait(app, "forgot.done", timeout: 60)
        E2E.snap(app, "code reset", in: self)
        E2E.tap(app, "forgot.finish")

        // The new code opens the space; the reminder is answered.
        E2E.unlock(app, "333333")
        E2E.snap(app, "space with new code", in: self)
    }

    @MainActor func testStartOverErasesEverything() {
        let app = E2E.launch(["-devCodes", "111111,222222"])
        E2E.wait(app, "entry.screen", timeout: 30)
        E2E.tap(app, "entry.forgot")
        E2E.tap(app, "forgot.erase")
        let field = E2E.wait(app, "entry.startOver.field")
        field.tap()
        field.typeText("ERASE")
        E2E.snap(app, "erase confirm", in: self)
        E2E.tap(app, "entry.startOver.erase")
        E2E.wait(app, "onboarding.welcome", timeout: 20)
        E2E.snap(app, "back to onboarding", in: self)
    }
}
