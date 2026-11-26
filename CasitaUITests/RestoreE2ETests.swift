import XCTest

/// Backup and restore, the way someone with a new iPhone does it: a backup
/// made on "the old phone" (first launch), then a fresh install restores it
/// from the welcome screen with the recovery sentence and a space's code.
final class RestoreE2ETests: XCTestCase {
    @MainActor func testInterruptedRestoreResumesAndAnotherCodeCanBeRestoredLater() {
        let old = E2E.launch(["-devCodes", "111111,222222", "-devRecoveryWords", "-devWriteBackup"])
        E2E.wait(old, "entry.screen", timeout: 30)
        old.terminate()
        let app = E2E.launch(["-devBackupFile"])
        E2E.wait(app, "onboarding.welcome", timeout: 15)
        E2E.tap(app, "onboarding.restore")
        E2E.tap(app, "restore.choose")
        enterSentence(app)
        app.terminate()
        app.launchArguments = ["-ignoreCapture"]
        app.launch()
        E2E.wait(app, "entry.screen", timeout: 20)
        resume(app, code: "111111")
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.lock")
        resume(app, code: "222222")
        E2E.unlock(app, "222222")
        E2E.snap(app, "private space recovered later without erase", in: self)
    }

    /// "Restore a space" keeps the entry screen's waits: during one, the
    /// sentence and a code restore nothing.
    @MainActor func testRestoreASpaceRefusesDuringAWait() {
        let app = E2E.launch(["-devCodes", "111111,222222", "-devRecoveryWords"])
        E2E.wait(app, "entry.screen", timeout: 30)
        for _ in 0..<5 {
            E2E.type(app, "999999")
            sleep(2)
        }
        E2E.wait(app, "entry.wait", timeout: 15)
        E2E.tap(app, "entry.forgot")
        E2E.tap(app, "forgot.restore")
        enterSentence(app)
        let field = E2E.wait(app, "code.field")
        field.tap()
        field.typeText("222222")
        E2E.tap(app, "code.submit")
        let refused = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Too many wrong codes'")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 10))
        XCTAssertFalse(E2E.element(app, "restore.done").exists)
        E2E.snap(app, "restore refused during a wait", in: self)
    }

    @MainActor private func enterSentence(_ app: XCUIApplication) {
        let phrase = E2E.wait(app, "restore.phrase")
        phrase.tap()
        phrase.typeText(E2E.devPhrase)
        E2E.tap(app, "restore.go")
        E2E.wait(app, "restore.codes", timeout: 120)
    }

    @MainActor private func resume(_ app: XCUIApplication, code: String) {
        E2E.tap(app, "entry.forgot")
        E2E.tap(app, "forgot.restore")
        enterSentence(app)
        let field = E2E.wait(app, "code.field")
        field.tap()
        field.typeText(code)
        E2E.tap(app, "code.submit")
        E2E.tap(app, "restore.done", timeout: 30)
        E2E.wait(app, "forgot.choose")
        E2E.tap(app, "onboarding.back")
        E2E.wait(app, "entry.screen")
    }

    @MainActor func testRestoreFromBackupWithWordsAndCode() {
        // The old phone: two spaces, sealed to the test words, backed up.
        let old = E2E.launch(["-devCodes", "111111,222222", "-devRecoveryWords", "-devWriteBackup"])
        E2E.wait(old, "entry.screen", timeout: 30)
        old.terminate()

        // The new phone: nothing on it yet.
        let app = E2E.launch(["-devBackupFile"])
        E2E.wait(app, "onboarding.welcome", timeout: 15)
        sleep(3)
        E2E.snap(app, "welcome with restore", in: self)
        E2E.tap(app, "onboarding.restore")
        E2E.wait(app, "restore.file")
        E2E.snap(app, "restore file", in: self)
        E2E.tap(app, "restore.choose")

        E2E.wait(app, "restore.words")
        // A word that isn't Casita's first: refused in plain words.
        let phrase = E2E.wait(app, "restore.phrase")
        phrase.tap()
        let wrong = E2E.devPhrase.replacingOccurrences(of: "red", with: "xqzzy")
        phrase.typeText(wrong)
        E2E.snap(app, "sentence typed", in: self)
        E2E.tap(app, "restore.go")
        XCTAssertTrue(E2E.element(app, "restore.problem").waitForExistence(timeout: 5))
        E2E.snap(app, "unknown word", in: self)
        // Then right, with a slip it forgives ("brigde").
        // The cursor goes to the end, wherever the sentence wraps (a narrow
        // screen wraps it onto more lines, and a tap in the middle lands mid-text).
        phrase.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.97)).tap()
        phrase.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: wrong.count + 10))
        phrase.typeText(E2E.devPhrase.replacingOccurrences(of: "tiny bridge is", with: "tiny brigde is"))
        E2E.tap(app, "restore.go")

        E2E.wait(app, "restore.codes", timeout: 120)
        E2E.snap(app, "backup unlocked", in: self)
        let field = E2E.wait(app, "code.field")
        field.tap()
        field.typeText("222222")
        E2E.tap(app, "code.submit")
        E2E.wait(app, "restore.done", timeout: 30)
        E2E.snap(app, "space restored", in: self)
        E2E.tap(app, "restore.done")

        E2E.unlock(app, "222222")
        E2E.snap(app, "restored space open", in: self)
    }
}
