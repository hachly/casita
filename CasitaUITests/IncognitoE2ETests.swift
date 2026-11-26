import XCTest

/// Incognito in Web keeps nothing: a cookie a site sets there is gone once
/// Incognito closes or Casita locks, and never reaches the space's own Web.
/// Needs the network (httpbin.org echoes the cookies it is sent).
final class IncognitoE2ETests: XCTestCase {
    private let cookie = "nothingsaved"

    @MainActor func testIncognitoKeepsNothing() {
        let app = E2E.launch(["-devCodes", "111111,222222", "-devSubscribed"])
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.web")
        E2E.wait(app, "web.incognito")
        sleep(1)
        E2E.snap(app, "web", in: self)

        // A cookie set in Incognito is there while it is open...
        E2E.tap(app, "web.incognito")
        E2E.wait(app, "browser.incognito.start")
        E2E.wait(app, "browser.incognito")
        sleep(1)
        E2E.snap(app, "incognito start", in: self)
        go(app, "httpbin.org/cookies/set?casita=\(cookie)")
        XCTAssertTrue(shows(app, cookie), "Incognito holds the cookie while open")
        E2E.snap(app, "incognito with a cookie", in: self)

        // ...and gone once it closes.
        E2E.tap(app, "browser.close")
        E2E.tap(app, "web.incognito")
        go(app, "httpbin.org/cookies")
        XCTAssertTrue(shows(app, "cookies"))
        XCTAssertFalse(shows(app, cookie, timeout: 1), "closing Incognito must forget the cookie")

        // A lock while Incognito is open forgets it too.
        E2E.tap(app, "browser.address")
        go(app, "httpbin.org/cookies/set?casita=\(cookie)")
        XCTAssertTrue(shows(app, cookie))
        E2E.goHome(app)
        sleep(2)
        app.activate()
        E2E.unlock(app, "111111")
        // A short lock reopens Web, but never the Incognito page.
        E2E.wait(app, "web.incognito", timeout: 20)
        XCTAssertFalse(E2E.element(app, "browser.incognito").exists, "Incognito must not be reopened after a lock")
        E2E.tap(app, "web.incognito")
        go(app, "httpbin.org/cookies")
        XCTAssertTrue(shows(app, "cookies"))
        XCTAssertFalse(shows(app, cookie, timeout: 1), "a lock must forget Incognito")
        E2E.snap(app, "incognito after a lock", in: self)

        // Nothing reached the space's own Web: no site added, no cookie.
        E2E.tap(app, "browser.close")
        let address = E2E.wait(app, "web.address")
        XCTAssertFalse(E2E.element(app, "web.bookmark.httpbin.org").exists)
        address.tap()
        address.typeText("httpbin.org/cookies\n")
        E2E.wait(app, "browser.screen", timeout: 15)
        XCTAssertTrue(shows(app, "cookies"))
        XCTAssertFalse(shows(app, cookie, timeout: 1), "Incognito must never reach the space's logins")
        E2E.snap(app, "space web without the cookie", in: self)
    }

    /// Types a site into the browser's address field and opens it.
    @MainActor private func go(_ app: XCUIApplication, _ site: String) {
        let field = E2E.wait(app, "browser.field")
        let clear = E2E.element(app, "browser.clear")
        if clear.exists { clear.tap() }  // the field opens holding the page's address
        field.tap()
        field.typeText(site + "\n")
    }

    /// Whether the page on screen shows this text.
    @MainActor private func shows(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20) -> Bool {
        app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            .waitForExistence(timeout: timeout)
    }
}
