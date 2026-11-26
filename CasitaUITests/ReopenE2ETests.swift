import XCTest

/// "Reopen where I was": a short lock comes back to the same screen, in the
/// same space only, and not when the setting is off.
final class ReopenE2ETests: XCTestCase {
    private let codes = ["-devCodes", "111111,222222", "-devSubscribed"]

    @MainActor private func leaveAndCome(_ app: XCUIApplication, code: String) {
        E2E.goHome(app)
        sleep(2)
        app.activate()
        E2E.wait(app, "entry.screen", timeout: 20)
        E2E.type(app, code)
    }

    @MainActor func testReopensWhereItWasInTheSameSpaceOnly() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")

        // Settings, then a short lock: back in Settings.
        E2E.tap(app, "space.tile.settings")
        E2E.wait(app, "settings.screen")
        leaveAndCome(app, code: "111111")
        E2E.wait(app, "settings.screen", timeout: 20)
        E2E.snap(app, "reopened in settings", in: self)

        // A Web page, then a short lock: back on the page.
        E2E.back(app)
        E2E.tap(app, "space.tile.web")
        let address = E2E.wait(app, "web.address")
        address.tap()
        address.typeText("en.wikipedia.org\n")
        E2E.wait(app, "browser.screen", timeout: 15)
        sleep(6)
        leaveAndCome(app, code: "111111")
        E2E.wait(app, "browser.screen", timeout: 25)
        sleep(4)
        E2E.snap(app, "reopened on the page", in: self)

        // The other space's code opens that space's own home, not the page.
        leaveAndCome(app, code: "222222")
        E2E.wait(app, "space.tile.web", timeout: 20)
        XCTAssertFalse(E2E.element(app, "browser.screen").exists, "Another space must not reopen this one's page")
        E2E.snap(app, "other space at home", in: self)
    }

    @MainActor func testOffOpensHome() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.settings")
        E2E.tap(app, "settings.reopen")
        E2E.tap(app, "settings.reopen.0")
        E2E.snap(app, "reopen off", in: self)
        leaveAndCome(app, code: "111111")
        E2E.wait(app, "space.tile.settings", timeout: 20)
        XCTAssertFalse(E2E.element(app, "settings.screen").exists, "Off must open the space's home")
    }
}
