import XCTest

/// Clean screenshots of the real app with realistic content, for the App
/// Store frames. Skipped unless STORE_SHOTS=1:
///   TEST_RUNNER_STORE_SHOTS=1 xcodebuild … -only-testing:CasitaUITests/StoreShotsE2ETests test
/// Every attachment is named "store-…".
final class StoreShotsE2ETests: XCTestCase {
    private let english = ["-AppleLocale", "en_US", "-AppleLanguages", "(en)"]

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STORE_SHOTS"] == "1", "Store screenshots run only on request")
    }

    @MainActor func testInsideASpace() {
        let app = E2E.launch(["-devCodes", "111111,222222", "-devSubscribed"] + english)
        E2E.wait(app, "entry.screen", timeout: 30)
        sleep(1)
        E2E.snap(app, "store-entry", in: self)
        E2E.unlock(app, "222222")
        sleep(2)
        E2E.snap(app, "store-space", in: self)

        // Spaces under this one.
        E2E.tap(app, "space.tile.spaces")
        for (name, code) in [("Work", "331100"), ("Travel", "442200"), ("Family", "553300")] {
            E2E.tap(app, "spaces.new")
            let field = E2E.wait(app, "spaces.new.name")
            field.tap()
            field.typeText(name)
            E2E.tap(app, "spaces.new.next")
            for _ in 0..<2 {
                let code1 = E2E.wait(app, "code.field")
                code1.tap()
                code1.typeText(code)
                E2E.tap(app, "code.submit")
            }
            E2E.wait(app, "spaces.row.\(name)", timeout: 30)
        }
        sleep(3)
        E2E.snap(app, "store-spaces", in: self)
        E2E.back(app)

        // Photos: nine from the library.
        E2E.tap(app, "space.tile.photos")
        E2E.tap(app, "photos.add")
        let squares = app.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertTrue(squares.firstMatch.waitForExistence(timeout: 15))
        // The picker runs in another process and stops answering queries once
        // a photo is selected, so read the grid once and tap by position. Its
        // columns differ between a phone and an open iPhone Duo.
        let frames = squares.allElementsBoundByIndex.prefix(9).map(\.frame)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        var picked = 0
        for frame in frames {
            origin.withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * 0.3)).tap()
            usleep(300_000)
            picked += 1
        }
        let add = app.buttons["Add"]
        if add.waitForExistence(timeout: 5) { add.tap() } else { app.buttons["Done"].tap() }
        let keep = app.buttons["Keep them"]
        if keep.waitForExistence(timeout: 60) { keep.tap() }
        // A tap can miss a square under the picker's bars; most land.
        E2E.wait(app, "photos.cell.\(max(0, picked - 3))", timeout: 30)
        sleep(2)
        E2E.snap(app, "store-photos", in: self)
        E2E.tap(app, "photos.cell.1")
        E2E.wait(app, "viewer.screen")
        sleep(2)
        E2E.snap(app, "store-viewer", in: self)
        E2E.tap(app, "viewer.close")
        E2E.back(app)

        E2E.tap(app, "space.tile.web")
        E2E.wait(app, "web.screen")
        sleep(2)
        E2E.snap(app, "store-web", in: self)
        E2E.back(app)

        E2E.tap(app, "space.tile.settings")
        E2E.wait(app, "settings.screen")
        sleep(1)
        E2E.snap(app, "store-settings", in: self)
        let privacy = E2E.element(app, "settings.privacy")
        for _ in 0..<5 where !privacy.isHittable { app.swipeUp() }
        privacy.tap()
        E2E.wait(app, "privacy.screen")
        sleep(1)
        E2E.snap(app, "store-privacy", in: self)
    }

    @MainActor func testPaywall() {
        let app = E2E.launch(["-devCodes", "111111,222222"] + english)
        E2E.unlock(app, "111111")
        // The free plan adds photos; another space needs a plan.
        E2E.tap(app, "space.tile.spaces")
        E2E.tap(app, "spaces.new")
        E2E.waitForPlans(app, timeout: 30)
        // Frame 8 sells Lifetime: show it chosen, with its one-payment terms.
        E2E.tap(app, "paywall.plan.lifetime")
        sleep(2)
        E2E.snap(app, "store-paywall", in: self)
    }

    @MainActor func testOnboarding() {
        let app = E2E.launch(english)
        E2E.wait(app, "onboarding.welcome", timeout: 15)
        sleep(4)
        E2E.snap(app, "store-welcome-0", in: self)
        for page in 1...3 {
            E2E.tap(app, "onboarding.next")
            sleep(2)
            E2E.snap(app, "store-welcome-\(page)", in: self)
        }
    }
}
