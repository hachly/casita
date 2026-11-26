import Foundation
import Testing
@testable import Casita

@Suite struct FreePlanTests {
    private func fixture() async throws -> (ReservedStorage, SpaceRef, SpaceRef, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("storage")
        let stretcher = PBKDF2Stretcher(iterations: 1000)
        let seed = try ReservedStorage.create(at: url, bytes: Int64(ReservedStorage.chunksOffset + 240 * ReservedStorage.chunkSealed), stretcher: stretcher)
        await seed.setCodeWrapIterations(1000)
        let top = try await seed.createTopSpace(code: "private")
        _ = try await seed.createChild(of: top, name: "Everyday", code: "everyday", chunks: 80)
        await seed.lockAll()
        let storage = try ReservedStorage.open(at: url, stretcher: stretcher, access: .free)
        await storage.setMinimumUnlockDuration(.milliseconds(1))
        let a = try #require(try await storage.unlock(code: "private"))
        let b = try #require(try await storage.unlock(code: "everyday"))
        return (storage, a, b, directory)
    }

    /// The count under Photos and Files, and the note above Lock from 40.
    @Test func freeWordingCountsDownToTheAllowance() {
        #expect(FreePlan.countLine(used: 42) == "42 of 50 on Free")
        #expect(FreePlan.headsUp(used: 39) == nil)
        #expect(FreePlan.headsUp(used: 40) == "10 more photos or files fit on Free. See plans")
        #expect(FreePlan.headsUp(used: 49) == "1 more photo or file fits on Free. See plans")
        #expect(FreePlan.headsUp(used: 50) == "50 of 50 on Free. See plans to keep adding.")
        #expect(FreePlan.headsUp(used: 61) == "50 of 50 on Free. See plans to keep adding.")
    }

    @Test func itemAllowanceIsPerSpaceAndChecksBothWritePaths() async throws {
        let (storage, a, b, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<50 { try await storage.writeFile(named: "\(index).txt", data: Data([1]), in: a) }
        await #expect(throws: PlanLimit.items) { try await storage.writeFile(named: "51.txt", data: Data([2]), in: a) }
        let external = directory.appendingPathComponent("external")
        try Data([3]).write(to: external)
        await #expect(throws: PlanLimit.items) { try await storage.writeFile(named: "stream.txt", from: external, in: a) }
        try await storage.writeFile(named: "0.txt", from: external, in: a)
        try await storage.writeFile(named: "app/index", data: Data([4]), in: a)
        try await storage.writeFile(named: "0.txt.thumb", data: Data([5]), in: a)
        try await storage.writeFile(named: "other-space.txt", data: Data([6]), in: b)
        #expect(try await storage.userItemCount(in: a) == 50)
        #expect(try await storage.userItemCount(in: b) == 1)
        try await storage.deleteFile(named: "1.txt", in: a)
        try await storage.writeFile(named: "replacement.txt", from: external, in: a)
        #expect(try await storage.userItemCount(in: a) == 50)
    }

    @Test func competingImportsCannotOvershoot() async throws {
        let (storage, a, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<49 { try await storage.writeFile(named: "\(index)", data: Data([1]), in: a) }
        let admitted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<10 {
                group.addTask {
                    do { try await storage.writeFile(named: "racing-\(index)", data: Data([2]), in: a); return true }
                    catch { return false }
                }
            }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(admitted == 1)
        #expect(try await storage.userItemCount(in: a) == 50)
    }

    @Test func importedNamesCannotMasqueradeAsInternalFiles() async throws {
        let (storage, a, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["app/index", "web/session.json", "picture.thumb", "", "folder\\thing"] {
            let safe = try await storage.availableUserFileName(name, in: a)
            #expect(FreePlan.isUserItem(safe))
            try await storage.writeFile(named: safe, data: Data([1]), in: a)
        }
        #expect(try await storage.userItemCount(in: a) == 5)
    }

    @Test func growthAndExtraSpacesRequireAPlan() async throws {
        let (storage, a, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: PlanLimit.spaces) { try await storage.createChild(of: a, name: "New", code: "new", chunks: 4) }
        await #expect(throws: PlanLimit.storage) { try await storage.grow(for: a, toBytes: 50_000_000) }
    }

    @Test func freeTimelineKeepsExistingOrganisationWithoutSortingNewImports() {
        let old = MediaItem(name: "old.jpg"), new = MediaItem(name: "new.jpg")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var facts = PhotoFacts()
        facts.photos[old.name] = PhotoFacts.Photo(taken: date)
        let added = [old.name: date, new.name: date]
        let free = SmartAlbums(library: [old, new], facts: facts, added: added, allowsNewTimeline: false)
        let paid = SmartAlbums(library: [old, new], facts: facts, added: added)
        #expect(free.years.flatMap(\.items) == [old])
        #expect(Set(paid.years.flatMap(\.items)) == Set([old, new]))
        #expect(free.dates[new.name] == date, "Manual ordering still has the new item's date")
    }

    @Test func webAppSelectionIsAtomicPerSpaceAndSurvivesReopen() async throws {
        let (storage, a, b, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instagram = URL(string: "https://www.instagram.com/")!
        let telegram = URL(string: "https://web.telegram.org/")!
        let lease = NavigationLease()
        #expect(try await storage.authorizeWebApp(instagram, in: a, lease: lease))
        #expect(try await !storage.authorizeWebApp(telegram, in: a, lease: lease))
        #expect(try await storage.authorizeWebApp(telegram, in: b, lease: lease))
        let again = try ReservedStorage.open(at: storage.url, stretcher: PBKDF2Stretcher(iterations: 1000), access: .free)
        let reopened = try #require(try await again.unlock(code: "private"))
        #expect(try await again.freeWebApp(in: reopened) == "instagram.com")
        #expect(try await !again.authorizeWebApp(telegram, in: reopened, lease: lease))
    }

    @Test func cancelledAndLockedNavigationCannotClaimAnApp() async throws {
        let (storage, a, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = NavigationLease()
        lease.cancel()
        await #expect(throws: CancellationError.self) {
            try await storage.authorizeWebApp(URL(string: "https://x.com")!, in: a, lease: lease)
        }
        #expect(try await storage.freeWebApp(in: a) == nil)
        await storage.lockAll()
        await #expect(throws: StorageError.noSuchSpace) {
            try await storage.authorizeWebApp(URL(string: "https://x.com")!, in: a, lease: NavigationLease())
        }
    }

    @Test func simultaneousFirstAppsAdmitOnlyOne() async throws {
        let (storage, a, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let accepted = try await withThrowingTaskGroup(of: Bool.self, returning: Int.self) { group in
            for host in ["instagram.com", "telegram.org", "x.com", "youtube.com"] {
                group.addTask { try await storage.authorizeWebApp(URL(string: "https://\(host)")!, in: a, lease: NavigationLease()) }
            }
            var count = 0
            for try await result in group where result { count += 1 }
            return count
        }
        #expect(accepted == 1)
    }

    @Test func expiredAndRestoredOverLimitContentRemainsAvailable() async throws {
        let (initial, _, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paid = try ReservedStorage.open(at: initial.url, stretcher: PBKDF2Stretcher(iterations: 1000))
        await paid.setCodeWrapIterations(1000)
        let top = try #require(try await paid.unlock(code: "private"))
        let key = RecoveryKey()
        try await paid.setRecoveryKey(key, from: top)
        for index in 0..<55 { try await paid.addUserFile(named: "item-\(index).txt", data: Data([UInt8(index)]), in: top) }
        try await paid.writeFile(named: "web/saved-session", data: Data([9]), in: top)
        let extra = try await paid.createChild(of: top, name: "Extra", code: "extra", chunks: 4)
        try await paid.writeFile(named: "kept.txt", data: Data([7]), in: extra)
        await paid.lockAll()

        // Reopen with expired access: the same encrypted content is retained.
        let expired = try ReservedStorage.open(at: initial.url, stretcher: PBKDF2Stretcher(iterations: 1000), access: .free)
        let expiredTop = try #require(try await expired.unlock(code: "private"))
        #expect(try await expired.userItemCount(in: expiredTop) == 55)
        #expect(try await expired.readFile(named: "item-54.txt", in: expiredTop) == Data([54]))
        #expect(try await expired.readFile(named: "web/saved-session", in: expiredTop) == Data([9]))
        #expect(try await expired.children(of: expiredTop).contains("Extra"))
        await #expect(throws: PlanLimit.items) { try await expired.addUserFile(named: "more.txt", data: Data([1]), in: expiredTop) }
        try await expired.writeFile(named: "item-0.txt", data: Data([6]), in: expiredTop)

        // Manual backup and full restore remain available above the limit.
        let backup = directory.appendingPathComponent("backup")
        try await expired.writeBackup(to: backup)
        let restoredURL = directory.appendingPathComponent("restored")
        _ = try ReservedStorage.restore(backup: backup, recoveryKey: key, to: restoredURL, stretcher: PBKDF2Stretcher(iterations: 1000))
        let restored = try ReservedStorage.open(at: restoredURL, stretcher: PBKDF2Stretcher(iterations: 1000), access: .free)
        await restored.setCodeWrapIterations(1000)
        let restoredTop = try #require(try await restored.adopt(code: "private", recoveryKey: key))
        #expect(try await restored.userItemCount(in: restoredTop) == 55)
        #expect(try await restored.readFile(named: "item-0.txt", in: restoredTop) == Data([6]))
        let restoredChild = try await restored.openChild(of: restoredTop, named: "Extra")
        #expect(try await restored.readFile(named: "kept.txt", in: restoredChild) == Data([7]))
        for index in 0..<6 { try await restored.deleteFile(named: "item-\(index).txt", in: restoredTop) }
        let sharedFile = directory.appendingPathComponent("shared")
        try Data([8]).write(to: sharedFile)
        try await restored.addUserFile(named: "from-share.txt", from: sharedFile, in: restoredTop)
        await #expect(throws: PlanLimit.items) { try await restored.addUserFile(named: "another-share.txt", from: sharedFile, in: restoredTop) }
        #expect(try await restored.userItemCount(in: restoredTop) == 50)
    }

    @Test func signInExceptionsAreNarrowAndCannotBeUsedAsFirstApp() async throws {
        let (storage, a, _, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = NavigationLease()
        let signIn = URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=test")!
        #expect(try await storage.authorizeWebApp(URL(string: "https://duckduckgo.com/?q=Instagram")!, in: a, lease: lease))
        #expect(try await storage.freeWebApp(in: a) == nil)
        #expect(try await !storage.authorizeWebApp(signIn, in: a, lease: lease, signInFlow: true))
        #expect(try await storage.authorizeWebApp(URL(string: "https://youtube.com")!, in: a, lease: lease))
        #expect(try await storage.authorizeWebApp(signIn, in: a, lease: lease, signInFlow: true))
        #expect(try await !storage.authorizeWebApp(signIn, in: a, lease: lease))
        #expect(try await !storage.authorizeWebApp(URL(string: "https://mail.google.com")!, in: a, lease: lease, signInFlow: true))
        #expect(try await !storage.authorizeWebApp(URL(string: "https://facebook.com/")!, in: a, lease: lease, signInFlow: true))
        #expect(WebAppIdentity.app(for: URL(string: "https://a.co.uk")!) != WebAppIdentity.app(for: URL(string: "https://b.co.uk")!))
        #expect(WebAppIdentity.app(for: URL(string: "https://twitter.com")!) == "x.com")
        #expect(WebAppIdentity.app(for: URL(string: "https://instagram.com.attacker.test")!) != "instagram.com")
    }
}
