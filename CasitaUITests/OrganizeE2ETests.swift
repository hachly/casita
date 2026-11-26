import XCTest

/// Albums in Photos, and folders and text files in Files: made, filled,
/// renamed, moved into and deleted, the way a person would.
final class OrganizeE2ETests: XCTestCase {
    private let codes = ["-devCodes", "111111,222222", "-devSubscribed"]

    @MainActor private func typeInAlert(_ app: XCUIApplication, _ text: String, then button: String) {
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The alert asks for a name")
        field.typeText(text)
        app.alerts.buttons[button].tap()
    }

    @MainActor func testAlbums() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.photos")
        E2E.tap(app, "photos.add")
        E2E.pickPhotos(app, count: 1)
        let keep = app.buttons["Keep them"]
        XCTAssertTrue(keep.waitForExistence(timeout: 30))
        keep.tap()
        E2E.wait(app, "photos.cell.0", timeout: 20)

        // Sort and show.
        E2E.tap(app, "photos.sort")
        let oldest = app.buttons["Oldest first"]
        XCTAssertTrue(oldest.waitForExistence(timeout: 5), "The sort menu offers Oldest first")
        E2E.snap(app, "sort menu", in: self)
        oldest.tap()

        // Add to a new album from the photo's menu.
        E2E.element(app, "photos.cell.0").press(forDuration: 1.2)
        let addToAlbum = app.buttons["Add to album"]
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 5))
        addToAlbum.tap()
        E2E.tap(app, "albumPicker.new")
        typeInAlert(app, "Trip", then: "Create")

        // The album holds it.
        E2E.tap(app, "photos.tab.albums")
        E2E.wait(app, "albums.card.Trip", timeout: 10)
        sleep(1)
        E2E.snap(app, "albums", in: self)
        E2E.tap(app, "albums.card.Trip")
        E2E.wait(app, "album.screen")
        E2E.wait(app, "album.cell.0")
        E2E.snap(app, "album", in: self)

        // Renamed from its menu.
        E2E.tap(app, "album.menu")
        let rename = app.buttons["Rename album"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The field starts with the old name; clear it first.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Holiday")
        E2E.snap(app, "rename typed", in: self)
        app.alerts.buttons["Rename"].tap()
        E2E.back(app)
        E2E.wait(app, "albums.card.Holiday", timeout: 10)

        // A new album, filled from the chooser.
        E2E.tap(app, "albums.new")
        typeInAlert(app, "Empty", then: "Create")
        E2E.tap(app, "album.empty.add", timeout: 10)
        E2E.tap(app, "chooser.cell.0")
        E2E.snap(app, "chooser", in: self)
        E2E.tap(app, "chooser.add")
        E2E.wait(app, "album.cell.0", timeout: 10)
        E2E.snap(app, "album filled", in: self)
    }

    /// The simulator's library: Apple's samples (California, Iceland, dated
    /// 2009 to 2018), food photos with no date, and two portraits stamped
    /// Lisbon, May 2023. In the simulator Vision's models give every face
    /// the same print, so both portraits make one person there.
    @MainActor func testAutomaticAlbums() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.photos")
        E2E.tap(app, "photos.add")
        E2E.pickPhotos(app)
        let keep = app.buttons["Keep them"]
        XCTAssertTrue(keep.waitForExistence(timeout: 60))
        keep.tap()

        // Sorted on the iPhone while Albums shows.
        E2E.tap(app, "photos.tab.albums")
        E2E.snap(app, "sorting", in: self)
        XCTAssertTrue(E2E.element(app, "albums.sorting").waitForNonExistence(timeout: 120), "Sorting finishes")
        E2E.wait(app, "albums.section.places", timeout: 10)
        E2E.wait(app, "albums.section.timeline")
        E2E.wait(app, "albums.section.people")
        E2E.snap(app, "albums with automatic ones", in: self)
        app.swipeUp()
        E2E.snap(app, "albums scrolled", in: self)

        // A place: both Lisbon portraits.
        E2E.tap(app, "albums.place.Lisbon")
        E2E.wait(app, "album.screen")
        E2E.wait(app, "album.cell.1")
        XCTAssertFalse(E2E.element(app, "album.cell.2").exists, "Only the two Lisbon photos")
        E2E.snap(app, "place", in: self)
        E2E.back(app)

        // A year, by month: Apple's three Iceland photos, August 2012. The
        // shelf runs newest first, so 2012 is off to the right.
        let year = E2E.wait(app, "albums.year.2012", timeout: 10)
        for _ in 0..<4 where !app.frame.contains(year.frame) { E2E.element(app, "albums.section.timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 150, dy: 120)).press(forDuration: 0.05, thenDragTo: E2E.element(app, "albums.section.timeline").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -150, dy: 120))) }
        // Let the shelf settle: a moving card takes no tap.
        sleep(1)
        year.tap()
        E2E.wait(app, "album.section.August")
        E2E.wait(app, "album.cell.2")
        // The cells exist while the page still slides in; a Back tapped then
        // can land on a photo.
        sleep(1)
        E2E.snap(app, "year", in: self)
        E2E.back(app)
        E2E.wait(app, "photos.screen")
        E2E.snap(app, "back from year", in: self)

        // A person: named, then told one photo isn't them.
        app.swipeDown()
        E2E.tap(app, "albums.person.0", timeout: 10)
        E2E.tap(app, "person.addName")
        typeInAlert(app, "Ines", then: "Save")
        XCTAssertTrue(app.staticTexts["Ines"].firstMatch.waitForExistence(timeout: 5), "The person is named")
        E2E.wait(app, "album.cell.1")
        E2E.snap(app, "person named", in: self)
        // Newest first: Leo's portrait (21 May) leads.
        E2E.element(app, "album.cell.0").press(forDuration: 1.2)
        let notHer = app.buttons["Not Ines"]
        XCTAssertTrue(notHer.waitForExistence(timeout: 5), "The photo's menu offers Not Ines")
        notHer.tap()
        XCTAssertTrue(E2E.element(app, "album.cell.1").waitForNonExistence(timeout: 5), "The photo left her")
        E2E.wait(app, "album.cell.0")
        E2E.back(app)
        XCTAssertTrue(app.staticTexts["Ines"].firstMatch.waitForExistence(timeout: 5), "Named, she stays with one photo")
        E2E.snap(app, "albums after naming", in: self)

        // Kept inside the space: a lock and a fresh unlock show the same.
        app.terminate()
        app.launchArguments = ["-ignoreCapture"]
        app.launch()
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.photos")
        E2E.tap(app, "photos.tab.albums")
        E2E.wait(app, "albums.place.Lisbon", timeout: 10)
        XCTAssertTrue(app.staticTexts["Ines"].firstMatch.waitForExistence(timeout: 5), "Her name was kept")
        XCTAssertFalse(E2E.element(app, "albums.sorting").exists, "Nothing is sorted twice")
    }

    @MainActor func testFoldersAndTextFiles() {
        let app = E2E.launch(codes)
        E2E.unlock(app, "111111")
        E2E.tap(app, "space.tile.files")

        // A folder.
        E2E.tap(app, "files.add")
        let newFolder = app.buttons["New folder"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5), "The add menu offers New folder")
        E2E.snap(app, "add menu", in: self)
        newFolder.tap()
        typeInAlert(app, "Work", then: "Create")
        E2E.wait(app, "files.folder.Work", timeout: 10)

        // A text file, written here.
        E2E.tap(app, "files.add")
        app.buttons["New text file"].tap()
        let name = E2E.wait(app, "textEditor.name")
        name.tap()
        name.typeText("Ideas")
        let body = E2E.element(app, "textEditor.body")
        body.tap()
        body.typeText("Buy milk")
        E2E.snap(app, "text editor", in: self)
        E2E.tap(app, "textEditor.save")
        E2E.wait(app, "files.row.Ideas.txt", timeout: 10)
        E2E.snap(app, "files with folder and text", in: self)

        // Moved into the folder.
        E2E.element(app, "files.row.Ideas.txt").press(forDuration: 1.2)
        let move = app.buttons["Move to folder"]
        XCTAssertTrue(move.waitForExistence(timeout: 5))
        move.tap()
        E2E.tap(app, "move.folder.Work")
        XCTAssertTrue(E2E.element(app, "files.row.Ideas.txt").waitForNonExistence(timeout: 5), "It left the top of Files")

        // Inside the folder, and still saying what was written.
        E2E.tap(app, "files.folder.Work")
        E2E.tap(app, "files.row.Ideas.txt", timeout: 10)
        let saved = E2E.wait(app, "textEditor.body")
        XCTAssertTrue((saved.value as? String ?? "").contains("Buy milk"), "The text was saved")
        app.buttons["Cancel"].tap()

        // A folder in the folder.
        E2E.tap(app, "files.add")
        app.buttons["New folder"].tap()
        typeInAlert(app, "Taxes", then: "Create")
        E2E.wait(app, "files.folder.Taxes", timeout: 10)
        E2E.snap(app, "inside Work", in: self)
        E2E.back(app)

        // Deleting the folder takes what's in it.
        E2E.element(app, "files.folder.Work").press(forDuration: 1.2)
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Delete folder"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        E2E.snap(app, "delete folder", in: self)
        confirm.tap()
        XCTAssertTrue(E2E.element(app, "files.folder.Work").waitForNonExistence(timeout: 5))
        E2E.wait(app, "files.empty", timeout: 10)
    }
}
