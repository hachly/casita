import CryptoKit
import Foundation
import Testing
@testable import Casita

/// Small files and a fast stretcher so the suite runs in seconds. The layout
/// and code paths are the same as the real sizes.
private let testBytes = Int64(ReservedStorage.chunksOffset + 40 * ReservedStorage.chunkSealed)
private let fast = PBKDF2Stretcher(iterations: 1000)

private func makeStorage(bytes: Int64 = testBytes) throws -> ReservedStorage {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("casita-\(UUID().uuidString).bin")
    return try ReservedStorage.create(at: url, bytes: bytes, stretcher: fast)
}

private func removeFile(_ storage: ReservedStorage) {
    try? FileManager.default.removeItem(at: storage.url)
}

@Suite struct ReservedStorageTests {
    @Test func rightCodeOpensAndWrongCodeDoesNot() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        await storage.setMinimumUnlockDuration(.milliseconds(1))
        let top = try await storage.createTopSpace(code: "847201")
        await storage.lock(top)

        let opened = try await storage.unlock(code: "847201")
        #expect(opened == top)
        #expect(try await storage.unlock(code: "000000") == nil)
    }

    @Test func fileSurvivesReopen() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        await storage.setMinimumUnlockDuration(.milliseconds(1))
        let top = try await storage.createTopSpace(code: "correct horse")
        try await storage.writeFile(named: "note.txt", data: Data("hello".utf8), in: top)

        let reopened = try ReservedStorage.open(at: storage.url, stretcher: fast)
        await reopened.setMinimumUnlockDuration(.milliseconds(1))
        let ref = try #require(try await reopened.unlock(code: "correct horse"))
        #expect(try await reopened.readFile(named: "note.txt", in: ref) == Data("hello".utf8))
    }

    @Test func largeFileSpansChunks() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "1")
        let big = ReservedStorage.randomBytes(ReservedStorage.chunkPlain * 2 + 777)
        try await storage.writeFile(named: "big", data: big, in: top)
        #expect(try await storage.readFile(named: "big", in: top) == big)
        try await storage.deleteFile(named: "big", in: top)
        #expect(try await storage.fileNames(in: top).isEmpty)
    }

    @Test func streamedWriteMatchesDataWrite() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "1")
        let big = ReservedStorage.randomBytes(ReservedStorage.chunkPlain * 3 + 12)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString).bin")
        try big.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await storage.writeFile(named: "streamed", from: url, in: top)
        #expect(try await storage.readFile(named: "streamed", in: top) == big)
    }

    @Test func childOpensWithItsCodeAndFromParent() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        await storage.setMinimumUnlockDuration(.milliseconds(1))
        let top = try await storage.createTopSpace(code: "top")
        let everyday = try await storage.createChild(of: top, name: "Everyday", code: "2580", chunks: 10)
        try await storage.writeFile(named: "a", data: Data("everyday".utf8), in: everyday)
        #expect(try await storage.children(of: top) == ["Everyday"])

        await storage.lockAll()
        let byCode = try #require(try await storage.unlock(code: "2580"))
        #expect(try await storage.readFile(named: "a", in: byCode) == Data("everyday".utf8))

        await storage.lockAll()
        let parent = try #require(try await storage.unlock(code: "top"))
        let fromParent = try await storage.openChild(of: parent, named: "Everyday")
        #expect(fromParent == everyday)
        #expect(try await storage.readFile(named: "a", in: fromParent) == Data("everyday".utf8))
    }

    @Test func childCannotSeeParentRoom() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "top")
        let topFree = try await storage.freeBytes(in: top)
        let child = try await storage.createChild(of: top, name: "c", code: "child", chunks: 4)
        #expect(try await storage.freeBytes(in: child) < topFree)
        #expect(try await storage.children(of: child).isEmpty)
    }

    /// The top keeps an unlisted reserve, so after the default split the top
    /// and the everyday space see the same free room (to a header chunk).
    @Test func topAndEverydaySeeTheSameFreeRoom() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "top")
        let half = Int(try await storage.freeBytes(in: top) / Int64(ReservedStorage.chunkPlain)) / 2
        let everyday = try await storage.createChild(of: top, name: "Everyday", code: "day", chunks: half)
        let gap = try await storage.freeBytes(in: top) - storage.freeBytes(in: everyday)
        #expect(abs(gap) <= Int64(ReservedStorage.chunkPlain))
        #expect(try await storage.freeBytes(in: top) < Int64(testBytes) / 2)
    }

    @Test func topDrawsOnItsReserveWhenFull() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "top")
        let free = try await storage.freeBytes(in: top)
        let big = Data(repeating: 7, count: Int(free) + 3 * ReservedStorage.chunkPlain)
        try await storage.writeFile(named: "big", data: big, in: top)
        #expect(try await storage.readFile(named: "big", in: top) == big)
    }

    @Test func everySpaceHoldsAtMostFourChildren() async throws {
        let storage = try makeStorage(bytes: Int64(ReservedStorage.chunksOffset + 80 * ReservedStorage.chunkSealed))
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "top")
        for i in 0..<ReservedStorage.maxChildren {
            _ = try await storage.createChild(of: top, name: "c\(i)", code: "code\(i)", chunks: 2)
        }
        await #expect(throws: StorageError.noSlots) {
            try await storage.createChild(of: top, name: "extra", code: "extra", chunks: 2)
        }
    }

    @Test func duplicateCodeIsRefused() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "same")
        await #expect(throws: StorageError.codeInUse) {
            try await storage.createChild(of: top, name: "x", code: "same", chunks: 2)
        }
    }

    @Test func growAddsRoomToRequester() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "top")
        let child = try await storage.createChild(of: top, name: "c", code: "child", chunks: 4)
        let before = try await storage.freeBytes(in: child)
        try await storage.grow(for: child, toBytes: testBytes + 10 * Int64(ReservedStorage.chunkSealed))
        #expect(try await storage.freeBytes(in: child) == before + 10 * Int64(ReservedStorage.chunkPlain))
        let size = try FileManager.default.attributesOfItem(atPath: storage.url.path)[.size] as? Int64
        #expect(size == testBytes + 10 * Int64(ReservedStorage.chunkSealed))
    }

    @Test func deletingChildReturnsRoomAndKillsItsCode() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        await storage.setMinimumUnlockDuration(.milliseconds(1))
        let top = try await storage.createTopSpace(code: "top")
        let before = try await storage.freeBytes(in: top)
        let child = try await storage.createChild(of: top, name: "c", code: "child", chunks: 6)
        _ = try await storage.createChild(of: child, name: "gc", code: "grandchild", chunks: 2)
        try await storage.deleteChild(of: top, named: "c")
        #expect(try await storage.freeBytes(in: top) == before)
        #expect(try await storage.children(of: top).isEmpty)
        #expect(try await storage.unlock(code: "child") == nil)
        #expect(try await storage.unlock(code: "grandchild") == nil)
    }

    @Test func selfDeletedChildIsReclaimedByParent() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        let top = try await storage.createTopSpace(code: "top")
        let before = try await storage.freeBytes(in: top)
        let child = try await storage.createChild(of: top, name: "c", code: "child", chunks: 6)
        try await storage.deleteSelf(child)
        #expect(try await storage.children(of: top).isEmpty)
        #expect(try await storage.freeBytes(in: top) == before)
    }

    @Test func fileLooksTheSameWithOneSpaceOrFive() async throws {
        let one = try makeStorage()
        let five = try makeStorage()
        defer { removeFile(one); removeFile(five) }
        _ = try await one.createTopSpace(code: "a")
        let top = try await five.createTopSpace(code: "b")
        for i in 0..<4 {
            let child = try await five.createChild(of: top, name: "s\(i)", code: "code\(i)", chunks: 3)
            try await five.writeFile(named: "f", data: ReservedStorage.randomBytes(1000), in: child)
        }
        let a = try Data(contentsOf: one.url)
        let b = try Data(contentsOf: five.url)
        #expect(a.count == b.count)
        #expect(a.count == Int(testBytes))
        // Crude distribution check: both files are full of random-looking bytes.
        for file in [a, b] {
            let body = file.dropFirst(ReservedStorage.fileHeaderSize)
            let mean = Double(body.reduce(0) { $0 + Int($1) }) / Double(body.count)
            #expect(abs(mean - 127.5) < 1.5)
            #expect(!body.contains(Data(count: 64)))
        }
    }

    @Test func wrongAndRightCodesTakeTheSameTime() async throws {
        let storage = try makeStorage()
        defer { removeFile(storage) }
        await storage.setMinimumUnlockDuration(.milliseconds(300))
        _ = try await storage.createTopSpace(code: "right")
        await storage.lockAll()
        let clock = ContinuousClock()
        // Best of three, so a loaded Mac doesn't fail the comparison.
        var right = Duration.seconds(1), wrong = Duration.seconds(1)
        for _ in 0..<3 {
            right = min(right, try await clock.measure { _ = try await storage.unlock(code: "right") })
            await storage.lockAll()
            wrong = min(wrong, try await clock.measure { _ = try await storage.unlock(code: "wrong") })
        }
        #expect(right >= .milliseconds(300))
        #expect(wrong >= .milliseconds(300))
        let diff = right > wrong ? right - wrong : wrong - right
        #expect(diff < .milliseconds(60))
    }
}

@Suite struct CodeStretcherTests {
    @Test func sameInputSameKeyDifferentSaltDifferentKey() throws {
        let salt1 = ReservedStorage.randomBytes(32)
        let salt2 = ReservedStorage.randomBytes(32)
        let k1 = try fast.stretch(code: "x", salt: salt1)
        let k2 = try fast.stretch(code: "x", salt: salt1)
        let k3 = try fast.stretch(code: "x", salt: salt2)
        #expect(k1 == k2)
        #expect(k1 != k3)
    }

    @Test func defaultPicksSimulatorStandInWithoutSecureEnclave() {
        let stretcher: any CodeStretcher = .default
        #expect(SecureEnclave.isAvailable == (stretcher is SecureEnclaveStretcher))
    }
}
