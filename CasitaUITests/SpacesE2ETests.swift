import XCTest

/// Spaces under spaces: making one, and the "Switch to …?" question that
/// comes before opening it.
final class SpacesE2ETests: XCTestCase {
    @MainActor func testNewSpaceThenSwitchingAsksFirst() {
        let app = E2E.launch(["-devCodes", "111111,222222", "-devSubscribed"])
        E2E.unlock(app, "222222")
        E2E.tap(app, "space.tile.spaces")
        E2E.wait(app, "spaces.screen")
        E2E.snap(app, "spaces empty", in: self)

        E2E.tap(app, "spaces.new")
        let name = E2E.wait(app, "spaces.new.name")
        name.tap()
        name.typeText("Work")
        E2E.snap(app, "new space name", in: self)
        E2E.tap(app, "spaces.new.next")
        for step in ["code", "code again"] {
            let field = E2E.wait(app, "code.field")
            field.tap()
            field.typeText("333333")
            E2E.snap(app, "new space \(step)", in: self)
            E2E.tap(app, "code.submit")
        }
        E2E.wait(app, "spaces.row.Work", timeout: 30)
        E2E.snap(app, "spaces with Work", in: self)

        E2E.tap(app, "spaces.row.Work")
        E2E.wait(app, "spaces.switch.screen")
        E2E.snap(app, "switch question", in: self)
        E2E.tap(app, "spaces.switch.cancel")
        XCTAssertTrue(E2E.element(app, "spaces.screen").waitForExistence(timeout: 5), "Cancel must stay on the list")

        E2E.tap(app, "spaces.row.Work")
        E2E.tap(app, "spaces.switch.confirm")
        E2E.wait(app, "space.screen", timeout: 20)
        E2E.snap(app, "inside Work", in: self)
    }
}
