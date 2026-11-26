import XCTest

/// Scrolling a web page counts as touching Casita: it stays open past the
/// one-minute idle lock while scrolled, and locks once left alone.
final class ScrollKeepsOpenE2ETests: XCTestCase {
    @MainActor func testScrollingAPageKeepsCasitaOpen() {
        let app = E2E.launch(["-devCodes", "111111,222222", "-devSubscribed"])
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.web")
        let address = E2E.wait(app, "web.address")
        address.tap()
        address.typeText("en.wikipedia.org\n")
        E2E.wait(app, "browser.screen", timeout: 15)
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15))

        // 90 s of scrolling, a swipe every 15 s: past the 60 s idle limit.
        for i in 0..<6 {
            sleep(15)
            if i % 2 == 0 { page.swipeUp(velocity: .slow) } else { page.swipeDown(velocity: .slow) }
            XCTAssertTrue(E2E.element(app, "browser.screen").exists, "Casita locked while the page was being scrolled (\(i))")
        }
        E2E.snap(app, "still open after 90 s of scrolling", in: self)

        // Left alone, it still locks.
        E2E.wait(app, "entry.screen", timeout: 80)
    }
}
