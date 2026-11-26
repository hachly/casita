import XCTest

/// Two spaces made at launch (`-devCodes everyday,private`): the entry
/// screen, opening and locking a space, and each feature screen.
final class SpaceE2ETests: XCTestCase {
    static let everyday = "111111"
    static let top = "222222"
    private var codes: [String] { ["-devCodes", "\(Self.everyday),\(Self.top)"] }

    @MainActor func testWrongCodeThenRightCodeOpensTheSpace() {
        let app = E2E.launch(codes + ["-devSubscribed"])
        E2E.wait(app, "entry.screen", timeout: 20)
        E2E.snap(app, "entry", in: self)
        E2E.type(app, "999999")
        let message = E2E.element(app, "entry.message")
        XCTAssertTrue(message.waitForExistence(timeout: 15))
        let wrong = NSPredicate(format: "label CONTAINS[c] 'wrong'")
        expectation(for: wrong, evaluatedWith: message)
        waitForExpectations(timeout: 15)
        E2E.snap(app, "wrong code", in: self)
        E2E.type(app, Self.everyday)
        E2E.wait(app, "space.screen", timeout: 20)
        E2E.snap(app, "everyday space", in: self)
        E2E.tap(app, "space.lock")
        E2E.wait(app, "entry.screen")
        E2E.unlock(app, Self.top)
        E2E.snap(app, "top space", in: self)
    }

    @MainActor func testUnlockMethodsAndDotGrids() {
        let app = E2E.launch(codes)
        E2E.wait(app, "entry.screen", timeout: 20)
        E2E.tap(app, "entry.method.dots")
        E2E.wait(app, "entry.dots.pad")
        for size in 3...6 {
            E2E.tap(app, "entry.dots.size.\(size)")
            E2E.snap(app, "dots \(size)x\(size)", in: self)
        }
        E2E.tap(app, "entry.method.password")
        E2E.wait(app, "entry.password")
        E2E.snap(app, "password", in: self)
        E2E.tap(app, "entry.method.numbers")
        E2E.wait(app, "entry.key.5")
        // Back on dots, the grid is 3×3 again: nothing remembers the size.
        E2E.tap(app, "entry.method.dots")
        XCTAssertTrue(E2E.element(app, "entry.dots.size.3").isSelected)
    }

    @MainActor func testEveryFeatureScreenOpens() {
        let app = E2E.launch(codes + ["-devSubscribed"])
        E2E.unlock(app, Self.everyday)

        E2E.tap(app, "space.tile.photos")
        E2E.wait(app, "photos.screen")
        E2E.snap(app, "photos", in: self)
        E2E.back(app)

        E2E.tap(app, "space.tile.camera")
        E2E.wait(app, "camera.screen")
        // The simulator has no camera: the calm explanation, never a crash.
        E2E.wait(app, "camera.unavailable")
        E2E.snap(app, "camera", in: self)
        E2E.tap(app, "camera.close")

        E2E.tap(app, "space.tile.files")
        E2E.wait(app, "files.screen")
        E2E.snap(app, "files", in: self)
        E2E.back(app)

        E2E.tap(app, "space.tile.web")
        E2E.wait(app, "web.screen")
        E2E.snap(app, "web", in: self)
        E2E.back(app)

        E2E.tap(app, "space.tile.spaces")
        E2E.wait(app, "spaces.screen")
        E2E.snap(app, "spaces", in: self)
        E2E.back(app)

        E2E.tap(app, "space.tile.settings")
        E2E.wait(app, "settings.screen")
        E2E.snap(app, "settings", in: self)
        app.swipeUp()
        E2E.snap(app, "settings lower", in: self)
    }

    /// Test builds' "Restart setup" erases everything and opens setup; in
    /// debug builds it also starts a new RevenueCat customer, so a plan
    /// bought before is gone and the trial is offered again.
    @MainActor func testRestartSetupErasesAndOpensSetup() {
        // It buys a plan, so it must not use the customer the other tests share.
        let app = E2E.launch(codes + ["-freshCustomer"])
        E2E.unlock(app, Self.everyday)

        // Buy a plan from the additional-space gate.
        E2E.tap(app, "space.tile.spaces")
        E2E.tap(app, "spaces.new")
        E2E.waitForPlans(app)
        E2E.tap(app, "paywall.buy")
        let valid = app.buttons["Test valid purchase"]
        XCTAssertTrue(valid.waitForExistence(timeout: 20), "RevenueCat Test Store sheet")
        valid.tap()
        XCTAssertTrue(E2E.element(app, "paywall.screen").waitForNonExistence(timeout: 20), "The paywall closes after buying")
        E2E.back(app)

        E2E.tap(app, "space.tile.settings")
        let row = E2E.element(app, "settings.restartSetup")
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        E2E.snap(app, "testing group", in: self)
        row.tap()
        let erase = app.alerts.buttons["Erase and restart"]
        XCTAssertTrue(erase.waitForExistence(timeout: 5))
        E2E.snap(app, "restart alert", in: self)
        erase.tap()
        E2E.wait(app, "onboarding.welcome", timeout: 15)
        E2E.snap(app, "setup again", in: self)

        // Same install, no fresh start: the new customer gets the trial.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-ignoreCapture", "-designGallery"]
        again.launch()
        E2E.tap(again, "gallery.paywall")
        E2E.waitForPlans(again)
        XCTAssertTrue(E2E.element(again, "paywall.buy").label.contains("free trial"), "The trial is offered again")
        E2E.snap(again, "trial again", in: self)
    }

    /// The questions above Lock: backups are asked once for all of Casita,
    /// the reset switch once in each space, and a yes turns each on.
    @MainActor func testNotesAskOnceAndTurnThingsOn() {
        let app = E2E.launch(codes + ["-devSubscribed"])
        E2E.unlock(app, Self.everyday)
        E2E.tap(app, "space.askBackup", timeout: 10)
        let backUp = app.alerts.buttons["Back up"]
        XCTAssertTrue(backUp.waitForExistence(timeout: 5))
        E2E.snap(app, "backup question", in: self)
        backUp.tap()
        E2E.tap(app, "space.askReset", timeout: 10)
        let turnOn = app.alerts.buttons["Turn on"]
        XCTAssertTrue(turnOn.waitForExistence(timeout: 5))
        E2E.snap(app, "reset question", in: self)
        turnOn.tap()
        E2E.wait(app, "space.tip", timeout: 10)

        // Locked and opened again: neither question comes back here.
        E2E.tap(app, "space.lock")
        E2E.unlock(app, Self.everyday)
        E2E.wait(app, "space.tip", timeout: 10)
        XCTAssertFalse(E2E.element(app, "space.askBackup").exists)
        XCTAssertFalse(E2E.element(app, "space.askReset").exists)
        E2E.tap(app, "space.tile.settings")
        let schedule = E2E.wait(app, "settings.backupSchedule")
        XCTAssertTrue(schedule.label.contains("Weekly"), "Backups are on: \(schedule.label)")
        E2E.back(app)

        // The other space asks only its own reset question.
        E2E.tap(app, "space.lock")
        E2E.unlock(app, Self.top)
        E2E.wait(app, "space.askReset", timeout: 10)
        XCTAssertFalse(E2E.element(app, "space.askBackup").exists, "Backups were answered for all of Casita")
        E2E.snap(app, "other space asks its own", in: self)
    }

    /// Back up now used to kill Casita: the save sheet took its file name
    /// from the backup's Transferable, which had none.
    @MainActor func testBackUpNowOpensTheSaveSheet() {
        let app = E2E.launch(codes)
        E2E.unlock(app, Self.top)
        E2E.tap(app, "space.tile.settings")
        E2E.tap(app, "settings.backupNow")
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), "The save sheet never opened")
        XCTAssertEqual(app.state, .runningForeground, "Casita quit on Back up now")
        E2E.snap(app, "save sheet", in: self)
    }

    @MainActor func testCreatingAnotherSpaceShowsAClosablePaywall() {
        let app = E2E.launch(codes)
        E2E.unlock(app, Self.everyday)
        E2E.tap(app, "space.tile.spaces")
        E2E.tap(app, "spaces.new")
        E2E.wait(app, "paywall.screen")
        XCTAssertFalse(E2E.element(app, "paywall.intro.continue").exists, "Adding opens on the trial page, not the benefits")
        E2E.waitForPlans(app)
        E2E.snap(app, "paywall from add", in: self)
        E2E.tap(app, "paywall.close")
        E2E.wait(app, "spaces.screen")
    }
}
