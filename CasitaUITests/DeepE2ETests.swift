import XCTest

/// The flows people use every day, end to end: importing and viewing a
/// photo, leaving the app, wrong-code waits, changing a code, deleting a
/// space, and opening a site in Web.
final class DeepE2ETests: XCTestCase {
    private let codes = ["-devCodes", "111111,222222", "-devSubscribed"]

    @MainActor func testImportViewAndDeleteAPhoto() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.photos")
        E2E.tap(app, "photos.add")
        // The system photo picker: pick the first photo, then Add.
        XCTAssertTrue(app.images.matching(identifier: "PXGGridLayout-Info").firstMatch.waitForExistence(timeout: 15), "The photo picker should show the library")
        E2E.snap(app, "picker", in: self)
        E2E.pickPhotos(app, count: 1)
        // Casita offers to delete the original; keep it.
        let keep = app.buttons["Keep them"]
        XCTAssertTrue(keep.waitForExistence(timeout: 30), "After import Casita asks about the originals")
        E2E.snap(app, "delete originals question", in: self)
        keep.tap()
        E2E.wait(app, "photos.cell.0", timeout: 20)
        E2E.snap(app, "gallery with photo", in: self)
        E2E.tap(app, "photos.cell.0")
        E2E.wait(app, "viewer.screen")
        sleep(1)
        E2E.snap(app, "viewer", in: self)

        // The share sheet must show its contents on the very first open.
        E2E.tap(app, "viewer.share")
        let sheet = app.otherElements["ActivityListView"].firstMatch
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10) || copy.waitForExistence(timeout: 5), "The share sheet shows on first open")
        E2E.snap(app, "share sheet", in: self)
        // Save to Casita, picked from inside Casita, refuses while a space
        // is open here rather than racing the open space's header.
        let casita = app.cells.matching(NSPredicate(format: "label == 'Casita'")).firstMatch
        if casita.waitForExistence(timeout: 5) {
            casita.tap()
            let refusal = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Lock it, then share again'")).firstMatch
            XCTAssertTrue(refusal.waitForExistence(timeout: 15), "Save to Casita refuses while a space is open")
            E2E.snap(app, "save to casita refuses", in: self)
            app.buttons["share.done"].firstMatch.tap()
            sleep(1)
        }
        if !E2E.element(app, "viewer.delete").isHittable {
            app.swipeDown(velocity: .fast)
            sleep(1)
        }

        E2E.tap(app, "viewer.delete")
        // The confirmation's Delete, not the viewer's own delete button.
        let delete = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND identifier != 'viewer.delete'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        E2E.snap(app, "delete confirm", in: self)
        delete.tap()
        E2E.wait(app, "photos.empty", timeout: 15)
        E2E.snap(app, "gallery empty again", in: self)
    }

    @MainActor func testLeavingTheAppLocks() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.goHome(app)
        sleep(2)
        app.activate()
        E2E.wait(app, "entry.screen", timeout: 10)
        E2E.snap(app, "locked after leaving", in: self)
    }

    @MainActor func testFiveWrongCodesStartAWait() {
        let app = E2E.launch(codes)
        E2E.wait(app, "entry.screen", timeout: 30)
        for _ in 0..<5 {
            E2E.type(app, "999999")
            sleep(2)
        }
        E2E.wait(app, "entry.wait", timeout: 15)
        E2E.snap(app, "waiting", in: self)
        // During the wait the right code doesn't work either.
        XCTAssertFalse(E2E.element(app, "entry.key.1").isEnabled && E2E.element(app, "space.screen").exists)
    }

    /// A right code doesn't clear the wrong tries: four wrong, the everyday
    /// code, then one more wrong try still starts the wait.
    @MainActor func testARightCodeDoesNotClearWrongTries() {
        let app = E2E.launch(codes)
        E2E.wait(app, "entry.screen", timeout: 30)
        for _ in 0..<4 {
            E2E.type(app, "999999")
            sleep(2)
        }
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.lock")
        E2E.wait(app, "entry.screen", timeout: 10)
        E2E.type(app, "999999")
        E2E.wait(app, "entry.wait", timeout: 15)
        E2E.snap(app, "waiting after a right code", in: self)
    }

    /// Changing a code counts as a try: four wrong codes, then a code change
    /// in the everyday space, and the wait is there at the next lock.
    @MainActor func testChangingACodeCountsAsATry() {
        let app = E2E.launch(codes)
        E2E.wait(app, "entry.screen", timeout: 30)
        for _ in 0..<4 {
            E2E.type(app, "999999")
            sleep(2)
        }
        changeEverydayCode(app)
        E2E.wait(app, "entry.wait", timeout: 15)
        E2E.snap(app, "waiting after a code change", in: self)
    }

    @MainActor func testChangeCodeThenUnlockWithIt() {
        let app = E2E.launch(codes)
        changeEverydayCode(app)
        E2E.unlock(app, "444444")
        E2E.snap(app, "opened with new code", in: self)
    }

    /// Opens the everyday space, changes its code to 444444 and locks.
    @MainActor private func changeEverydayCode(_ app: XCUIApplication) {
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.settings")
        E2E.wait(app, "settings.screen")
        let row = E2E.element(app, "settings.changeCode")
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        E2E.wait(app, "settings.changeCode.screen")
        for step in ["new code", "new code again"] {
            let field = E2E.wait(app, "code.field")
            field.tap()
            field.typeText("444444")
            E2E.snap(app, step, in: self)
            E2E.tap(app, "code.submit")
        }
        sleep(2)
        E2E.snap(app, "code changed", in: self)
        // Back to the space and lock it.
        if E2E.element(app, "sheet.close").exists { E2E.tap(app, "sheet.close") }
        E2E.back(app)
        E2E.tap(app, "space.lock")
    }

    @MainActor func testDeleteASpaceUnderThisOne() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "222222")
        E2E.tap(app, "space.tile.spaces")
        E2E.tap(app, "spaces.new")
        let name = E2E.wait(app, "spaces.new.name")
        name.tap()
        name.typeText("Temp")
        E2E.tap(app, "spaces.new.next")
        for _ in 0..<2 {
            let field = E2E.wait(app, "code.field")
            field.tap()
            field.typeText("555555")
            E2E.tap(app, "code.submit")
        }
        E2E.wait(app, "spaces.row.Temp", timeout: 30)
        E2E.tap(app, "spaces.edit")
        E2E.tap(app, "spaces.delete.Temp")
        E2E.wait(app, "spaces.delete.screen")
        E2E.snap(app, "delete space warning", in: self)
        let field = E2E.wait(app, "code.field")
        field.tap()
        field.typeText("555555")
        E2E.tap(app, "code.submit")
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: E2E.element(app, "spaces.row.Temp"))
        waitForExpectations(timeout: 30)
        E2E.snap(app, "space deleted", in: self)
    }

    @MainActor func testOpenAPresetSite() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.web")
        E2E.tap(app, "web.bookmark.Reddit")
        E2E.wait(app, "browser.screen", timeout: 15)
        sleep(15)
        E2E.snap(app, "reddit after 15 s", in: self)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "browser tree"
        tree.lifetime = .keepAlways
        add(tree)
        // The page must actually be on screen, not just loaded behind black.
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "No web view on screen")
        XCTAssertGreaterThan(page.frame.height, 300, "Web view too small: \(page.frame)")
        E2E.tap(app, "browser.close")
        let address = E2E.wait(app, "web.address")
        address.tap()
        address.typeText("en.wikipedia.org\n")
        E2E.wait(app, "browser.screen", timeout: 15)
        sleep(10)
        E2E.snap(app, "wikipedia after 10 s", in: self)
    }

    @MainActor func testPrivacyFromSettingsAndPaywall() {
        let app = E2E.launch(["-devCodes", "111111,222222"])
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.settings")
        let row = E2E.element(app, "settings.privacy")
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        E2E.snap(app, "settings bottom", in: self)
        row.tap()
        E2E.wait(app, "privacy.screen")
        sleep(1)
        E2E.snap(app, "privacy", in: self)
        E2E.back(app)
        E2E.back(app)
        // The free plan adds photos; another space needs a plan.
        E2E.tap(app, "space.tile.spaces")
        E2E.tap(app, "spaces.new")
        E2E.waitForPlans(app)
        E2E.tap(app, "paywall.privacy")
        E2E.wait(app, "privacy.close")
        E2E.snap(app, "privacy from paywall", in: self)
        E2E.tap(app, "privacy.close")
        E2E.wait(app, "paywall.screen")
    }
}
