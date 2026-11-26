import XCTest

final class FreePlanE2ETests: XCTestCase {
    @MainActor func testFirstWebAppIsFreeAndSecondShowsClosablePaywall() {
        let app = E2E.launch(["-devCodes", "111111,222222"])
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.web")
        E2E.tap(app, "web.bookmark.Instagram")
        E2E.wait(app, "browser.screen")
        XCTAssertFalse(E2E.element(app, "paywall.screen").exists)
        E2E.tap(app, "browser.close")
        E2E.tap(app, "web.bookmark.Telegram")
        E2E.wait(app, "paywall.screen", timeout: 20)
        XCTAssertTrue(E2E.element(app, "paywall.close").isHittable)
        XCTAssertFalse(app.buttons["Continue with Free"].exists)
        E2E.snap(app, "second app upgrade", in: self)
        E2E.tap(app, "paywall.close")
        E2E.wait(app, "web.screen")
        E2E.tap(app, "web.bookmark.Instagram")
        E2E.wait(app, "browser.screen")
        XCTAssertFalse(E2E.element(app, "paywall.screen").exists)

        // A different address inside the permitted browser must not bypass
        // the app tile's gate, even if the first site has no connection.
        E2E.tap(app, "browser.address")
        let clear = E2E.element(app, "browser.clear")
        if clear.exists { clear.tap() }
        let field = E2E.wait(app, "browser.field")
        field.tap()
        field.typeText("https://web.telegram.org/\n")
        E2E.wait(app, "paywall.screen", timeout: 20)
        E2E.tap(app, "paywall.close")
        app.terminate()
        app.launchArguments = ["-ignoreCapture"]
        app.launch()
        E2E.unlock(app, "111111")
        if !E2E.element(app, "web.screen").exists { E2E.tap(app, "space.tile.web") }
        // Resume may reopen the allowed page; return to app tiles.
        if E2E.element(app, "browser.close").exists { E2E.tap(app, "browser.close") }
        E2E.tap(app, "web.bookmark.Telegram")
        E2E.wait(app, "paywall.screen", timeout: 20)
    }

    /// Near the allowance the space says how many more fit, Photos and Files
    /// show the count, and both open the plans with the comparison.
    @MainActor func testNearTheAllowanceShowsCountAndPlans() {
        let app = E2E.launch(["-devCodes", "111111,222222", "-devFreeItems", "42"])
        E2E.unlock(app, "111111")
        XCTAssertTrue(E2E.wait(app, "space.freeRoom").label.contains("8 more photos or files fit on Free"))
        E2E.tap(app, "space.freeRoom")
        E2E.waitForPlans(app)
        E2E.wait(app, "paywall.compare")
        E2E.snap(app, "plans from free note", in: self)
        E2E.tap(app, "paywall.close")
        E2E.tap(app, "space.tile.files")
        E2E.wait(app, "free.count")
        XCTAssertTrue(app.staticTexts["42 of 50 on Free ·"].exists)
        E2E.tap(app, "free.seePlans")
        E2E.wait(app, "paywall.compare", timeout: 20)
        E2E.tap(app, "paywall.close")
        E2E.wait(app, "files.screen")
    }

    @MainActor func testFiftyItemsGateAddingButKeepExistingFilesAccessible() {
        let app = E2E.launch(["-devCodes", "111111,222222", "-devFullFreeSpace"])
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.photos")
        E2E.tap(app, "photos.add")
        E2E.wait(app, "paywall.screen")
        E2E.tap(app, "paywall.close")
        E2E.wait(app, "photos.screen")
        E2E.back(app)
        E2E.tap(app, "space.tile.files")
        E2E.wait(app, "files.screen")
        E2E.snap(app, "free files retained at limit", in: self)
    }
}
