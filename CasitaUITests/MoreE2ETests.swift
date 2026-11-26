import XCTest

/// Save to Casita from the Photos app, auto-lock, Make more room, and a new
/// recovery key from Settings.
final class MoreE2ETests: XCTestCase {
    private let codes = ["-devCodes", "111111,222222", "-devSubscribed"]

    @MainActor func testSaveToCasitaFromPhotos() {
        let app = E2E.launch(codes)
        E2E.wait(app, "entry.screen", timeout: 30)

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        for title in ["Continue", "Not Now", "OK"] where photos.buttons[title].waitForExistence(timeout: 2) {
            photos.buttons[title].tap()
        }
        let first = photos.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        // Photos reopens where it was left; go back to the Library grid.
        if !first.waitForExistence(timeout: 5) {
            let back = photos.buttons.matching(NSPredicate(format: "label == 'Back' OR identifier == 'Back'")).firstMatch
            if back.exists { back.tap() }
            let library = photos.buttons["LibraryTab"]
            if library.waitForExistence(timeout: 3) { library.tap() }
        }
        XCTAssertTrue(first.waitForExistence(timeout: 15), "Photos shows the library")
        E2E.snap(photos, "photos app", in: self)
        // Photos may cover the grid with a sheet the first time; swipe it away.
        if !first.isHittable { photos.swipeDown(velocity: .fast); sleep(1) }
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let share = photos.buttons.matching(NSPredicate(format: "label == 'Share' OR identifier == 'Share'")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        E2E.snap(photos, "photo open", in: self)
        share.tap()
        let casita = photos.cells.matching(NSPredicate(format: "label == 'Casita'")).firstMatch
        XCTAssertTrue(casita.waitForExistence(timeout: 10), "Casita in the share sheet")
        E2E.snap(photos, "share sheet", in: self)
        casita.tap()

        // The extension's own entry screen, the same as the app's.
        let key = photos.descendants(matching: .any).matching(identifier: "entry.key.1").firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 15), "The share extension shows the entry screen")
        E2E.snap(photos, "share entry", in: self)
        for _ in 0..<6 { key.tap() }
        photos.descendants(matching: .any).matching(identifier: "entry.key.ok").firstMatch.tap()
        let done = photos.descendants(matching: .any).matching(identifier: "share.done").firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "Saved")
        E2E.snap(photos, "saved", in: self)
        done.tap()

        app.activate()
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.photos")
        E2E.wait(app, "photos.cell.0", timeout: 15)
        E2E.snap(app, "photo arrived", in: self)
    }

    @MainActor func testIdleLocksAfterAMinute() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        sleep(70)
        E2E.wait(app, "entry.screen", timeout: 15)
    }

    @MainActor func testMakeMoreRoom() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.settings")
        E2E.tap(app, "settings.makeMoreRoom")
        E2E.wait(app, "settings.grow.screen")
        E2E.snap(app, "grow question", in: self)
        E2E.tap(app, "settings.grow.confirm")
        let size = E2E.element(app, "settings.reservedStorage")
        let grown = NSPredicate(format: "label CONTAINS '1 GB'")
        expectation(for: grown, evaluatedWith: size)
        waitForExpectations(timeout: 120)
        E2E.snap(app, "grown", in: self)
    }

    @MainActor func testNewRecoveryKeyFromSettings() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "222222")
        E2E.tap(app, "space.tile.settings")
        let row = E2E.element(app, "settings.newRecoveryKey")
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        row.tap()
        E2E.tap(app, "settings.newKey.confirm")
        E2E.wait(app, "onboarding.recovery.sentence", timeout: 15)
        E2E.snap(app, "new sentence", in: self)
        E2E.confirmSaved(app)
        E2E.wait(app, "settings.notice.screen", timeout: 30)
        E2E.snap(app, "new key saved", in: self)
    }

    /// Touches inside the system photo picker never reach Casita, so a slow
    /// pick must not idle-lock the space (found by the store screenshot run).
    @MainActor func testSlowPickDoesNotLock() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.photos")
        E2E.tap(app, "photos.add")
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        sleep(75)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"]
        // iOS 27's picker confirms with a check button named Done.
        if add.waitForExistence(timeout: 5) { add.tap() } else { app.buttons["Done"].firstMatch.tap() }
        let keep = app.buttons["Keep them"]
        if keep.waitForExistence(timeout: 30) { keep.tap() }
        E2E.wait(app, "photos.cell.0", timeout: 20)
        XCTAssertFalse(E2E.element(app, "entry.screen").exists, "Casita locked during a slow pick")
    }
}
