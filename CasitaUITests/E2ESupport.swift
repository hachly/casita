import XCTest

/// Shared steps for the end-to-end tests: they drive the real app the way a
/// person does, and save a screenshot of every screen they pass (named
/// "<test> · <step>") so each run can be reviewed by eye.
///
/// Every run starts from nothing (`-freshStart`, debug builds only). The
/// simulator panel streams the screen, which iOS reports as capture, so
/// `-ignoreCapture` keeps the privacy cover away.
@MainActor
enum E2E {
    static func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ignoreCapture", "-freshStart"] + args
        app.launch()
        return app
    }

    static func snap(_ app: XCUIApplication, _ name: String, in test: XCTestCase) {
        // The whole screen: an app screenshot leaves web pages black.
        let shot = XCTAttachment(screenshot: screen(of: app).screenshot())
        shot.name = "\(test.name) · \(name)"
        shot.lifetime = .keepAlways
        test.add(shot)
    }

    /// The element with this accessibility identifier, whatever its type.
    static func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    static func wait(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = element(app, id)
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "\(id) never appeared", file: file, line: line)
        return found
    }

    static func tap(_ app: XCUIApplication, _ id: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let found = wait(app, id, timeout: timeout, file: file, line: line)
        found.tap()
    }

    /// Types a code on the number pad and confirms it.
    static func type(_ app: XCUIApplication, _ code: String) {
        for digit in code { tap(app, "entry.key.\(digit)") }
        tap(app, "entry.key.ok")
    }

    /// Unlocking runs the code through the stretcher, about a second a try.
    static func unlock(_ app: XCUIApplication, _ code: String) {
        wait(app, "entry.screen", timeout: 20)
        type(app, code)
        wait(app, "space.screen", timeout: 20)
    }

    /// The screen the app is on. An open iPhone Duo shows apps on its inner
    /// screen, while `XCUIScreen.main` is the outer one, dark while open.
    static func screen(of app: XCUIApplication) -> XCUIScreen {
        guard XCUIScreen.screens.count > 1 else { return .main }
        let window = app.windows.firstMatch.frame.size
        return XCUIScreen.screens.first { screen in
            let size = screen.screenshot().image.size
            return abs(size.width - window.width) < 2 && abs(size.height - window.height) < 2
        } ?? .main
    }

    /// Sends Casita to the background. On the closed iPhone Duo simulator the
    /// Home button press does nothing, so the Home Screen is brought up instead.
    static func goHome(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5), "Casita should be in the background")
        }
    }

    /// Back out of a pushed screen. On a wide screen (an open iPhone Duo) the
    /// back button sits in the system's side bar, not in a navigation bar.
    static func back(_ app: XCUIApplication) {
        let back = app.buttons["BackButton"].firstMatch
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
    }

    /// Picks the first `count` photos in the system photo picker (every one
    /// when nil) and confirms. The picker runs in its own process and calls
    /// its squares not hittable, so they are tapped by position, high up,
    /// clear of its bottom bar.
    static func pickPhotos(_ app: XCUIApplication, count: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let first = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15), "The photo picker should show the library", file: file, line: line)
        let squares = app.images.matching(identifier: "PXGGridLayout-Info").allElementsBoundByIndex
        for square in squares.prefix(count ?? squares.count) {
            square.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        let add = app.buttons["Add"]
        if add.exists { add.tap() } else { app.buttons["Done"].tap() }
    }

    /// The sentence the debug builds' `-devRecoveryWords` seal to: the first
    /// word of every phrase list.
    static let devPhrase = "The tiny bridge is quietly walking through the tiny red bridge with a tiny bridge in Korea at dawn."

    /// "I saved it" on the recovery sentence, then the native check that it
    /// is never shown again.
    static func confirmSaved(_ app: XCUIApplication, snapIn test: XCTestCase? = nil, file: StaticString = #filePath, line: UInt = #line) {
        tap(app, "onboarding.recovery.saved", timeout: 15, file: file, line: line)
        let sure = app.alerts.buttons["I saved it"]
        XCTAssertTrue(sure.waitForExistence(timeout: 5), "Casita asks once more", file: file, line: line)
        if let test { snap(app, "never shown again", in: test) }
        sure.tap()
    }

    /// The paywall's plans have loaded.
    static func waitForPlans(_ app: XCUIApplication, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        wait(app, "paywall.plan.yearly", timeout: timeout, file: file, line: line)
    }
}
