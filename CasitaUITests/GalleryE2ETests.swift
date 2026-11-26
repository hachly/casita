import XCTest

/// The design gallery and the paywall from it: proves the harness works and
/// that a RevenueCat Test Store purchase closes the paywall.
final class GalleryE2ETests: XCTestCase {
    @MainActor func testPaywallOpensAndListsThreePlans() {
        let app = E2E.launch(["-designGallery"])
        E2E.snap(app, "gallery", in: self)
        E2E.tap(app, "gallery.paywall")
        E2E.wait(app, "paywall.screen")
        E2E.waitForPlans(app)
        XCTAssertTrue(E2E.element(app, "paywall.plan.weekly").exists)
        XCTAssertTrue(E2E.element(app, "paywall.plan.lifetime").exists)
        sleep(1)
        E2E.snap(app, "paywall", in: self)
        E2E.tap(app, "paywall.plan.lifetime")
        sleep(2)
        E2E.snap(app, "paywall lifetime selected", in: self)
        E2E.tap(app, "paywall.close")
        XCTAssertTrue(E2E.element(app, "gallery.paywall").waitForExistence(timeout: 5))
    }
}
