import Foundation
import Testing
@testable import Casita

@Suite struct AlbumsTests {
    @Test func albumsHoldFileNamesOnceNewestFirst() {
        var albums = Albums()
        let trip = albums.create("  Trip  ")
        #expect(trip.name == "Trip")
        albums.add(["a.jpg", "b.jpg"], to: trip.id)
        albums.add(["b.jpg", "c.mov"], to: trip.id)
        #expect(albums.albums[0].items == ["c.mov", "a.jpg", "b.jpg"])
        albums.remove("a.jpg", from: trip.id)
        #expect(albums.albums[0].items == ["c.mov", "b.jpg"])
    }

    @Test func deletedFilesLeaveEveryAlbum() {
        var albums = Albums()
        let one = albums.create("One"), two = albums.create("Two")
        albums.add(["a.jpg", "b.jpg"], to: one.id)
        albums.add(["b.jpg"], to: two.id)
        albums.prune(keeping: ["a.jpg"])
        #expect(albums.albums.map(\.items) == [[], ["a.jpg"]])
    }

    @Test func renameKeepsANameAndDeleteRemoves() {
        var albums = Albums()
        let one = albums.create("")
        #expect(one.name == "Album")
        albums.rename(one.id, to: "   ")
        #expect(albums.albums[0].name == "Album")
        albums.rename(one.id, to: "Family")
        #expect(albums.albums[0].name == "Family")
        albums.delete(one.id)
        #expect(albums.albums.isEmpty)
    }
}

@Suite struct FoldersTests {
    @Test func foldersNestAndNamesStayUnique() {
        var folders = Folders()
        let work = folders.create("Work", in: nil)
        let taxes = folders.create("Taxes", in: work)
        let again = folders.create("Work", in: nil)
        #expect(taxes == "Work/Taxes")
        #expect(again == "Work 2")
        #expect(folders.subfolders(of: nil) == ["Work", "Work 2"])
        #expect(folders.subfolders(of: "Work") == ["Work/Taxes"])
        // A slash in a name never makes a folder of its own.
        #expect(folders.create("a/b", in: nil) == "a-b")
    }

    @Test func filesMoveAndRenamingCarriesThemAlong() {
        var folders = Folders()
        let work = folders.create("Work", in: nil)
        let taxes = folders.create("Taxes", in: work)
        folders.move("plan.pdf", to: work)
        folders.move("2025.pdf", to: taxes)
        #expect(folders.isFile("plan.pdf", in: "Work"))
        #expect(folders.isFile("notes.txt", in: nil))
        let renamed = folders.rename(work, to: "Job")
        #expect(renamed == "Job")
        #expect(folders.folders.sorted() == ["Job", "Job/Taxes"])
        #expect(folders.placement == ["plan.pdf": "Job", "2025.pdf": "Job/Taxes"])
    }

    @Test func deletingAFolderReturnsEverythingInside() {
        var folders = Folders()
        let work = folders.create("Work", in: nil)
        let taxes = folders.create("Taxes", in: work)
        folders.move("plan.pdf", to: work)
        folders.move("2025.pdf", to: taxes)
        folders.move("notes.txt", to: nil)
        #expect(folders.delete(work) == ["2025.pdf", "plan.pdf"])
        #expect(folders.folders.isEmpty)
        #expect(folders.placement["notes.txt"] == nil)
        #expect(folders.placement.isEmpty)
    }

    @Test func pruneForgetsDeletedFiles() {
        var folders = Folders()
        folders.move("a.pdf", to: folders.create("Work", in: nil))
        folders.move("b.pdf", to: "Work")
        folders.prune(keeping: ["b.pdf"])
        #expect(folders.placement == ["b.pdf": "Work"])
    }
}
