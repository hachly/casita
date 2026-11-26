import Foundation
import Testing
import WebKit
@testable import Casita

/// Logins written for one space stay in that space and come back after the
/// storage file is closed and reopened.
@MainActor @Suite(.serialized) struct WebSpaceTests {
    private static let testBytes = Int64(ReservedStorage.chunksOffset + 40 * ReservedStorage.chunkSealed)
    private static let fast = PBKDF2Stretcher(iterations: 1000)

    private static func makeStorage() throws -> ReservedStorage {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("casita-web-\(UUID().uuidString).bin")
        return try ReservedStorage.create(at: url, bytes: testBytes, stretcher: fast)
    }

    private static func cookie(_ name: String, _ value: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: value, .domain: "www.instagram.com", .path: "/", .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 86_400 * 365),
        ])!
    }

    @Test func loginsStayInTheirSpaceAndSurviveRelaunch() async throws {
        let storage = try Self.makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.url) }
        await storage.setMinimumUnlockDuration(.milliseconds(1))
        let top = try await storage.createTopSpace(code: "top")
        let everyday = try await storage.createChild(of: top, name: "Everyday", code: "2580", chunks: 10)

        let topWeb = WebSpace(storage: storage, space: top)
        await topWeb.load()
        await topWeb.store.httpCookieStore.setCookie(Self.cookie("sessionid", "alpha"))
        await topWeb.save()
        #expect(topWeb.saveError == nil)
        #expect(try await storage.fileNames(in: top).contains(WebSpace.sessionFile))

        let everydayWeb = WebSpace(storage: storage, space: everyday)
        await everydayWeb.load()
        #expect(await everydayWeb.store.httpCookieStore.allCookies().isEmpty)
        #expect(try await storage.fileNames(in: everyday).isEmpty)

        await storage.lockAll()
        let reopened = try ReservedStorage.open(at: storage.url, stretcher: Self.fast)
        await reopened.setMinimumUnlockDuration(.milliseconds(1))
        let unlocked = try #require(try await reopened.unlock(code: "top"))
        let again = WebSpace(storage: reopened, space: unlocked)
        await again.load()
        let cookies = await again.store.httpCookieStore.allCookies()
        #expect(cookies.map(\.name) == ["sessionid"])
        #expect(cookies.first?.value == "alpha")

        let wrongSpace = try #require(try await reopened.unlock(code: "2580"))
        let other = WebSpace(storage: reopened, space: wrongSpace)
        await other.load()
        #expect(await other.store.httpCookieStore.allCookies().isEmpty)
    }

    @Test func bookmarksPersistAndSaveNeedsLoadFirst() async throws {
        let storage = try Self.makeStorage()
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let top = try await storage.createTopSpace(code: "top")

        let unloaded = WebSpace(storage: storage, space: top)
        await unloaded.save()
        #expect(try await storage.fileNames(in: top).isEmpty, "saving before load must not write an empty session")

        let web = WebSpace(storage: storage, space: top)
        await web.load()
        #expect(web.bookmarks == Bookmark.presets)
        await web.remove(Bookmark.presets[0])
        await web.add(URL(string: "https://login.casita.test/")!)
        #expect(web.bookmarks.map(\.name) == Bookmark.presets.dropFirst().map(\.name) + ["login.casita.test"])

        let again = WebSpace(storage: storage, space: top)
        await again.load()
        #expect(again.bookmarks == web.bookmarks)
    }
}
