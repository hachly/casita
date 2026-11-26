import CryptoKit
import Foundation
import Testing
@testable import Casita

private let testBytes = Int64(ReservedStorage.chunksOffset + 40 * ReservedStorage.chunkSealed)

private func tempURL(_ ext: String = "bin") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("casita-\(UUID().uuidString).\(ext)")
}

/// A storage with a top space, two children and a file in each, sealed to `key`.
private func makeStorage(key: RecoveryKey, stretcher: any CodeStretcher = PBKDF2Stretcher(iterations: 1000)) async throws -> ReservedStorage {
    let storage = try ReservedStorage.create(at: tempURL(), bytes: testBytes, stretcher: stretcher)
    await storage.setMinimumUnlockDuration(.milliseconds(1))
    await storage.setCodeWrapIterations(1000)
    let top = try await storage.createTopSpace(code: "top-code")
    try await storage.writeFile(named: "t", data: Data("top".utf8), in: top)
    let everyday = try await storage.createChild(of: top, name: "Everyday", code: "2580", chunks: 8)
    try await storage.writeFile(named: "e", data: Data("everyday".utf8), in: everyday)
    let deep = try await storage.createChild(of: everyday, name: "Deep", code: "dots-1-5-9", chunks: 3)
    try await storage.writeFile(named: "d", data: Data("deep".utf8), in: deep)
    try await storage.setRecoveryKey(key, from: top)
    return storage
}

private let codes = ["top-code": ("t", "top"), "2580": ("e", "everyday"), "dots-1-5-9": ("d", "deep")]

/// A restore on "another phone", with the test's fast settings.
private func restored(_ backup: URL, with words: RecoveryKey) async throws -> ReservedStorage {
    let storage = try ReservedStorage.restore(backup: backup, recoveryKey: words, to: tempURL(), stretcher: PBKDF2Stretcher(iterations: 1000))
    await storage.setMinimumUnlockDuration(.milliseconds(1))
    await storage.setCodeWrapIterations(1000)
    return storage
}

/// The portable slots as they are on disk, in slot order.
private func portableSlots(_ url: URL) throws -> [Data] {
    let file = try Data(contentsOf: url)
    return (0..<ReservedStorage.slotCount).map { slot in
        let start = Int(ReservedStorage.portableOffset(slot))
        return Data(file[start..<start + ReservedStorage.portableSlotSize])
    }
}

@Suite struct RecoveryKeyTests {
    @Test func twelveWordsRoundTrip() throws {
        let key = RecoveryKey()
        let words = key.words
        #expect(words.count == 12)
        #expect(words.allSatisfy { RecoveryKey.wordList.contains($0) })
        let parsed = try RecoveryKey(words: words.map { " \($0.uppercased()) " })
        #expect(parsed == key)
        #expect(parsed.publicKey(forSlot: 5).rawRepresentation == key.publicKey(forSlot: 5).rawRepresentation)
        // Every slot gets its own key from the same words.
        let keys = (0..<ReservedStorage.slotCount).map { key.publicKey(forSlot: $0).rawRepresentation }
        #expect(Set(keys).count == ReservedStorage.slotCount)
    }

    @Test func knownVectorMatchesBIP39() throws {
        // BIP-39 test vector: 16 zero bytes.
        let key = RecoveryKey(entropy: Data(count: 16))
        #expect(key.words == Array(repeating: "abandon", count: 11) + ["about"])
        let hex = "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f"
        let key2 = RecoveryKey(entropy: Data(stride(from: 0, to: hex.count, by: 2).map { UInt8(hex.dropFirst($0).prefix(2), radix: 16)! }))
        #expect(key2.words == ["legal", "winner", "thank", "year", "wave", "sausage", "worth", "useful", "legal", "winner", "thank", "yellow"])
    }

    @Test func typosAreCaught() throws {
        var words = RecoveryKey().words
        #expect(throws: RecoveryKeyError.wrongWordCount) { try RecoveryKey(words: Array(words.dropLast())) }
        words[3] = "notaword"
        #expect(throws: RecoveryKeyError.unknownWord("notaword")) { try RecoveryKey(words: words) }
        var checksumFails = 0
        for _ in 0..<16 {
            var w = RecoveryKey().words
            w[5] = w[5] == "abandon" ? "ability" : "abandon"
            if (try? RecoveryKey(words: w)) == nil { checksumFails += 1 }
        }
        // A 4-bit checksum catches 15 of 16 single-word slips.
        #expect(checksumFails >= 10)
    }

    @Test func twelveWordKeysStillReadWhereASentenceGoes() async throws {
        let key = RecoveryKey()
        try RecoveryKey.check(key.words.joined(separator: " "))
        #expect(try await RecoveryKey.typed(key.words.joined(separator: "  ").uppercased()) == key)
    }
}

@Suite struct RecoveryPhraseTests {
    @Test func listsReadBackWithoutDoubt() {
        let lists = [PhraseWords.adjectives, PhraseWords.things, PhraseWords.manners, PhraseWords.actions.map(\.word),
                     PhraseWords.colours, PhraseWords.places, PhraseWords.times.map(\.word)]
        let all = lists.flatMap { $0 }
        #expect(Set(all).count == all.count, "Each word in one list only, once")
        #expect(all.allSatisfy { $0.allSatisfy { ("a"..."z").contains($0) } }, "Lowercase ASCII")
        #expect(all.allSatisfy { !PhraseWords.joining.contains($0) }, "No joining word is a part")
        #expect(PhraseWords.actions.allSatisfy { $0.then.isEmpty || PhraseWords.joining.contains($0.then) })
        #expect(PhraseWords.times.allSatisfy { PhraseWords.joining.contains($0.before) })
        let a = PhraseWords.adjectives.count, t = PhraseWords.things.count
        let bits = [a, t, PhraseWords.manners.count, PhraseWords.actions.count, a, PhraseWords.colours.count, t, a, t,
                    PhraseWords.places.count, PhraseWords.times.count]
            .reduce(0.0) { $0 + log2(Double($1)) }
        #expect(bits >= 86, "About 87 bits, then stretching on top")
        #expect(PhraseWords.manners.allSatisfy { $0.hasSuffix("ly") })
    }

    @Test func aSentenceReadsBackHoweverItIsTyped() throws {
        for _ in 0..<50 {
            let phrase = RecoveryPhrase()
            #expect(try RecoveryPhrase(typed: phrase.sentence) == phrase)
            #expect(try RecoveryPhrase(typed: phrase.sentence.uppercased()) == phrase)
            // Only the parts, in order, no joining words.
            #expect(try RecoveryPhrase(typed: phrase.parts.joined(separator: ", ")) == phrase)
        }
    }

    @Test func elevenPartsWithAOrAn() throws {
        let phrase = RecoveryPhrase(parts: ["sleepy", "giraffe", "happily", "walking", "dark", "brown", "forest", "icy", "banjo", "reykjavik", "midnight"])
        #expect(phrase.sentence == "The sleepy giraffe is happily walking through the dark brown forest with an icy banjo in Reykjavik at midnight.")
        #expect(try RecoveryPhrase(typed: phrase.sentence) == phrase)
        #expect(RecoveryPhrase().parts.count == 11)
        #expect(RecoveryPhrase.dev.sentence == "The tiny bridge is quietly walking through the tiny red bridge with a tiny bridge in Korea at dawn.")
    }

    /// Sentences made before 23 Oct 2026 have eight parts and still read.
    @Test func slipsAreForgivenOrCaught() throws {
        let phrase = RecoveryPhrase(parts: ["sleepy", "giraffe", "walking", "dark", "brown", "forest", "reykjavik", "midnight"])
        #expect(phrase.sentence == "The sleepy giraffe is walking through the dark brown forest in Reykjavik at midnight.")
        // Accents, a letter off, a letter missing, a missing "the".
        #expect(try RecoveryPhrase(typed: "the sleepy girafe is walkng through dark brown forest in Reykjavík at midnight") == phrase)
        #expect(throws: RecoveryKeyError.unknownWord("xqzzy")) {
            try RecoveryPhrase(typed: "the sleepy xqzzy is walking through the dark brown forest in reykjavik at midnight")
        }
        #expect(throws: RecoveryKeyError.wrongWordCount) { try RecoveryPhrase(typed: "the sleepy giraffe is walking") }
        #expect(RecoveryPhrase.editDistance("kitten", "sitting") == 3)
        #expect(RecoveryPhrase.editDistance("", "abc") == 3)
    }

    @Test func aPhraseStretchesToOneKeyEveryTime() async throws {
        let phrase = RecoveryPhrase.dev
        let fast = RecoveryKey(phrase: phrase, rounds: 1000)
        #expect(fast == RecoveryKey(phrase: try RecoveryPhrase(typed: phrase.sentence), rounds: 1000))
        #expect(fast != RecoveryKey(phrase: RecoveryPhrase(), rounds: 1000))
        #expect(fast.seed.count == 32)
    }

    /// The real stretching: about a second on an iPhone 11. Prints the time
    /// here, for tuning `phraseRounds` on each phone.
    @Test func stretchingTakesAboutASecond() async throws {
        let start = ContinuousClock.now
        let key = try await RecoveryKey.typed(RecoveryPhrase().sentence)
        let took = ContinuousClock.now - start
        print("STRETCH \(RecoveryKey.phraseRounds) rounds took \(took)")
        #expect(key.seed.count == 32)
        #expect(took < .seconds(5))
    }
}

@Suite struct BackupTests {
    @Test func backupRestoresOnAnotherPhoneWithEachCode() async throws {
        let key = RecoveryKey()
        let storage = try await makeStorage(key: key)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        // Automatic backups run while every space is locked.
        await storage.lockAll()
        let backup = tempURL(BackupFile.fileExtension)
        try await storage.writeBackup(to: backup)
        defer { try? FileManager.default.removeItem(at: backup) }
        let size = try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? Int64
        #expect(size == BackupFile.size(forStorageBytes: testBytes))

        // Another phone: different stretcher, and the salt rotates on restore.
        let restoredURL = tempURL()
        let restored = try ReservedStorage.restore(
            backup: backup, recoveryKey: try RecoveryKey(words: key.words),
            to: restoredURL, stretcher: PBKDF2Stretcher(iterations: 1500)
        )
        defer { try? FileManager.default.removeItem(at: restoredURL) }
        await restored.setMinimumUnlockDuration(.milliseconds(1))
        await restored.setCodeWrapIterations(1000)
        #expect(await restored.salt != storage.salt)
        #expect(await restored.portableSalt == storage.portableSalt)

        for (code, (name, content)) in codes {
            #expect(try await restored.unlock(code: code) == nil, "nothing opens before the code is adopted")
            let ref = try #require(try await restored.adopt(code: code, recoveryKey: key))
            #expect(try await restored.readFile(named: name, in: ref) == Data(content.utf8))
        }
        #expect(try await restored.adopt(code: "not-a-code", recoveryKey: key) == nil)

        await restored.lockAll()
        for (code, (name, content)) in codes {
            let ref = try #require(try await restored.unlock(code: code))
            #expect(try await restored.readFile(named: name, in: ref) == Data(content.utf8))
        }
        let top = try #require(try await restored.unlock(code: "top-code"))
        #expect(try await restored.children(of: top) == ["Everyday"])
        let everyday = try await restored.openChild(of: top, named: "Everyday")
        #expect(try await restored.children(of: everyday) == ["Deep"])

        // The restored file keeps working after it is closed and reopened.
        let again = try ReservedStorage.open(at: restoredURL, stretcher: PBKDF2Stretcher(iterations: 1500))
        await again.setMinimumUnlockDuration(.milliseconds(1))
        #expect(try await again.unlock(code: "2580") != nil)
    }

    @Test func twoBackupsOfTheSameStorageDifferButMatchInSize() async throws {
        let storage = try await makeStorage(key: RecoveryKey())
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let a = tempURL(), b = tempURL()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try await storage.writeBackup(to: a)
        try await storage.writeBackup(to: b)
        let da = try Data(contentsOf: a), db = try Data(contentsOf: b)
        #expect(da.count == db.count)
        #expect(da.prefix(8) == db.prefix(8))
        let same = zip(da.dropFirst(8), db.dropFirst(8)).filter { $0 == $1 }.count
        #expect(Double(same) / Double(da.count) < 0.01)
    }

    @Test func wrongWordsFailCleanly() async throws {
        let key = RecoveryKey()
        let storage = try await makeStorage(key: key)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let backup = tempURL()
        defer { try? FileManager.default.removeItem(at: backup) }
        try await storage.writeBackup(to: backup)
        let out = tempURL()
        #expect(throws: BackupError.wrongRecoveryKey) {
            try ReservedStorage.restore(backup: backup, recoveryKey: RecoveryKey(), to: out, stretcher: PBKDF2Stretcher(iterations: 1000))
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(throws: BackupError.notBackupFile) {
            try ReservedStorage.restore(backup: storage.url, recoveryKey: key, to: out, stretcher: PBKDF2Stretcher(iterations: 1000))
        }
        // Right file, wrong words at adopt time: nothing opens.
        let restored = try ReservedStorage.restore(backup: backup, recoveryKey: key, to: out, stretcher: PBKDF2Stretcher(iterations: 1000))
        defer { try? FileManager.default.removeItem(at: out) }
        await restored.setCodeWrapIterations(1000)
        #expect(try await restored.adopt(code: "2580", recoveryKey: RecoveryKey()) == nil)
    }

    @Test func resetTopCodeOnlyWhenOptedIn() async throws {
        let key = RecoveryKey()
        let storage = try await makeStorage(key: key)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        await storage.lockAll()
        await #expect(throws: BackupError.cannotReset) {
            _ = try await storage.resetCode(to: "new-top", with: key)
        }
        let top = try #require(try await storage.unlock(code: "top-code"))
        try await storage.setResetWithRecoveryKey(true, for: top)
        await storage.lockAll()
        await #expect(throws: BackupError.cannotReset) {
            _ = try await storage.resetCode(to: "new-top", with: RecoveryKey())
        }
        let reset = try await storage.resetCode(to: "new-top", with: key)
        #expect(reset == top)
        await storage.lockAll()
        #expect(try await storage.unlock(code: "top-code") == nil)
        let reopened = try #require(try await storage.unlock(code: "new-top"))
        #expect(try await storage.readFile(named: "t", in: reopened) == Data("top".utf8))
        // Children still open from the top after the reset.
        #expect(try await storage.children(of: reopened) == ["Everyday"])

        // The new code also travels through a backup.
        let backup = tempURL(), out = tempURL()
        defer { try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: out) }
        try await storage.writeBackup(to: backup)
        let restored = try ReservedStorage.restore(backup: backup, recoveryKey: key, to: out, stretcher: PBKDF2Stretcher(iterations: 1000))
        await restored.setCodeWrapIterations(1000)
        #expect(try await restored.adopt(code: "new-top", recoveryKey: key) != nil)
        #expect(try await restored.adopt(code: "top-code", recoveryKey: key) == nil)
        // Reset survives the restore too, and the old storage's opt-in off state is a throwaway seal.
        let fresh = try ReservedStorage.restore(backup: backup, recoveryKey: key, to: tempURL(), stretcher: PBKDF2Stretcher(iterations: 1000))
        await fresh.setCodeWrapIterations(1000)
        defer { try? FileManager.default.removeItem(at: fresh.url) }
        #expect(try await fresh.resetCode(to: "third", with: key) == top)
    }

    @Test func newRecoveryKeyResealsTheWholeTree() async throws {
        let old = RecoveryKey(), new = RecoveryKey()
        let storage = try await makeStorage(key: old)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let top = try #require(try await storage.unlock(code: "top-code"))
        try await storage.setRecoveryKey(new, from: top)
        let backup = tempURL()
        defer { try? FileManager.default.removeItem(at: backup) }
        try await storage.writeBackup(to: backup)
        #expect(throws: BackupError.wrongRecoveryKey) {
            try ReservedStorage.restore(backup: backup, recoveryKey: old, to: tempURL(), stretcher: PBKDF2Stretcher(iterations: 1000))
        }
        let restored = try ReservedStorage.restore(backup: backup, recoveryKey: new, to: tempURL(), stretcher: PBKDF2Stretcher(iterations: 1000))
        defer { try? FileManager.default.removeItem(at: restored.url) }
        await restored.setCodeWrapIterations(1000)
        for code in codes.keys {
            #expect(try await restored.adopt(code: code, recoveryKey: new) != nil, "\(code)")
        }
    }

    @Test func changingACodeKeepsItRestorable() async throws {
        let key = RecoveryKey()
        let storage = try await makeStorage(key: key)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let everyday = try #require(try await storage.unlock(code: "2580"))
        try await storage.setCode("1357", for: everyday)
        await #expect(throws: StorageError.codeInUse) { try await storage.setCode("top-code", for: everyday) }
        await storage.lockAll()
        #expect(try await storage.unlock(code: "2580") == nil)
        #expect(try await storage.unlock(code: "1357") == everyday)
        let backup = tempURL()
        defer { try? FileManager.default.removeItem(at: backup) }
        try await storage.writeBackup(to: backup)
        let restored = try ReservedStorage.restore(backup: backup, recoveryKey: key, to: tempURL(), stretcher: PBKDF2Stretcher(iterations: 1000))
        defer { try? FileManager.default.removeItem(at: restored.url) }
        await restored.setCodeWrapIterations(1000)
        #expect(try await restored.adopt(code: "1357", recoveryKey: key) == everyday)
    }

    /// A new key from a child re-seals the child and what is under it, and
    /// leaves every other portable slot byte for byte as it was. One backup
    /// then opens with either set of words, each reaching its own spaces.
    @Test func newKeyFromAChildCoversOnlyItsSubtree() async throws {
        let old = RecoveryKey(), new = RecoveryKey()
        let storage = try await makeStorage(key: old)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let everyday = try #require(try await storage.unlock(code: "2580"))
        let given = try await storage.state(everyday).header.givenSlots
        #expect(given.count < ReservedStorage.slotCount)

        let before = try portableSlots(storage.url)
        try await storage.setRecoveryKey(new, from: everyday)
        let after = try portableSlots(storage.url)
        for slot in 0..<ReservedStorage.slotCount {
            if given.contains(slot) {
                #expect(before[slot].prefix(32) != after[slot].prefix(32), "slot \(slot) gets a new key")
            } else {
                #expect(before[slot] == after[slot], "slot \(slot) is untouched")
            }
        }
        // Read back from disk, the child holds the new words' keys for its own
        // share of slots and no others.
        await storage.lockAll()
        let reopened = try #require(try await storage.unlock(code: "2580"))
        let keys = try await storage.state(reopened).header.recoveryKeys
        #expect(Set(keys.keys) == given)
        #expect(keys.allSatisfy { $0.value == new.publicKey(forSlot: $0.key).rawRepresentation })
        // A space made under it later starts on the new words.
        _ = try await storage.createChild(of: reopened, name: "Later", code: "7777", chunks: 1)

        await storage.lockAll()
        let backup = tempURL()
        defer { try? FileManager.default.removeItem(at: backup) }
        try await storage.writeBackup(to: backup)
        let size = try FileManager.default.attributesOfItem(atPath: backup.path)[.size] as? Int64
        #expect(size == BackupFile.size(forStorageBytes: testBytes))

        // Old words: the top, and through it every space under it.
        let withOld = try await restored(backup, with: old)
        defer { try? FileManager.default.removeItem(at: withOld.url) }
        for code in ["2580", "dots-1-5-9", "7777"] {
            #expect(try await withOld.adopt(code: code, recoveryKey: old) == nil, "\(code)")
        }
        let top = try #require(try await withOld.adopt(code: "top-code", recoveryKey: old))
        #expect(try await withOld.readFile(named: "t", in: top) == Data("top".utf8))
        let child = try await withOld.openChild(of: top, named: "Everyday")
        #expect(try await withOld.readFile(named: "e", in: child) == Data("everyday".utf8))

        // New words: the child and the space under it, never the top.
        let withNew = try await restored(backup, with: new)
        defer { try? FileManager.default.removeItem(at: withNew.url) }
        #expect(try await withNew.adopt(code: "top-code", recoveryKey: new) == nil)
        for (code, (name, content)) in codes where code != "top-code" {
            let ref = try #require(try await withNew.adopt(code: code, recoveryKey: new), "\(code)")
            #expect(try await withNew.readFile(named: name, in: ref) == Data(content.utf8))
        }
        #expect(try await withNew.adopt(code: "7777", recoveryKey: new) != nil)
        // The other words still work on the same restored file.
        #expect(try await withNew.adopt(code: "top-code", recoveryKey: old) != nil)
    }

    @Test func wordsThatMatchNoSpaceFailCleanly() async throws {
        let key = RecoveryKey(), gone = RecoveryKey()
        let storage = try await makeStorage(key: key)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let top = try #require(try await storage.unlock(code: "top-code"))
        // A space on words of its own opens with them...
        let work = try await storage.createChild(of: top, name: "Work", code: "9999", chunks: 2)
        try await storage.setRecoveryKey(gone, from: work)
        let withWork = tempURL()
        defer { try? FileManager.default.removeItem(at: withWork) }
        try await storage.writeBackup(to: withWork)
        let restoredWork = try await restored(withWork, with: gone)
        defer { try? FileManager.default.removeItem(at: restoredWork.url) }
        #expect(try await restoredWork.adopt(code: "9999", recoveryKey: gone) != nil)

        // ...until it is deleted: then its words match nothing.
        try await storage.deleteChild(of: top, named: "Work")
        let backup = tempURL()
        defer { try? FileManager.default.removeItem(at: backup) }
        try await storage.writeBackup(to: backup)
        for words in [gone, RecoveryKey()] {
            let out = tempURL()
            #expect(throws: BackupError.wrongRecoveryKey) {
                try ReservedStorage.restore(backup: backup, recoveryKey: words, to: out, stretcher: PBKDF2Stretcher(iterations: 1000))
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }

        // Spaces never given words are sealed to keys nobody holds.
        let bare = try ReservedStorage.create(at: tempURL(), bytes: testBytes, stretcher: PBKDF2Stretcher(iterations: 1000))
        defer { try? FileManager.default.removeItem(at: bare.url) }
        _ = try await bare.createTopSpace(code: "a")
        let bareBackup = tempURL()
        defer { try? FileManager.default.removeItem(at: bareBackup) }
        try await bare.writeBackup(to: bareBackup)
        #expect(throws: BackupError.wrongRecoveryKey) {
            try ReservedStorage.restore(backup: bareBackup, recoveryKey: key, to: tempURL(), stretcher: PBKDF2Stretcher(iterations: 1000))
        }
    }

    /// Spaces that share words still carry different keys in plain, so the
    /// file doesn't show which slots belong together.
    @Test func slotsOnTheSameWordsCantBeMatchedUp() async throws {
        let key = RecoveryKey()
        let storage = try await makeStorage(key: key)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let keys = try portableSlots(storage.url).map { $0.prefix(32) }
        #expect(Set(keys).count == ReservedStorage.slotCount)
        let top = try #require(try await storage.unlock(code: "top-code"))
        let everyday = try #require(try await storage.unlock(code: "2580"))
        #expect(keys[top.slot] == key.publicKey(forSlot: top.slot).rawRepresentation)
        #expect(keys[everyday.slot] == key.publicKey(forSlot: everyday.slot).rawRepresentation)
    }

    /// The reset switch belongs to one space: turning it on in a child
    /// touches only the child's share of slots, keeps their keys, and the
    /// words then reset the child's code and nothing else.
    @Test func resetFromAChildLeavesTheTopAlone() async throws {
        let key = RecoveryKey()
        let storage = try await makeStorage(key: key)
        defer { try? FileManager.default.removeItem(at: storage.url) }
        let top = try #require(try await storage.unlock(code: "top-code"))
        let everyday = try #require(try await storage.unlock(code: "2580"))
        let given = try await storage.state(everyday).header.givenSlots

        let before = try portableSlots(storage.url)
        try await storage.setResetWithRecoveryKey(true, for: everyday)
        let after = try portableSlots(storage.url)
        for slot in 0..<ReservedStorage.slotCount {
            if given.contains(slot) {
                #expect(before[slot].prefix(32) == after[slot].prefix(32), "slot \(slot) keeps its key")
                #expect(before[slot] != after[slot], "slot \(slot) is re-sealed")
            } else {
                #expect(before[slot] == after[slot], "slot \(slot) is untouched")
            }
        }
        #expect(try await storage.resetsWithRecoveryKey(top) == false)

        await storage.lockAll()
        #expect(try await storage.resetCode(to: "4444", with: key) == everyday)
        await storage.lockAll()
        #expect(try await storage.unlock(code: "2580") == nil)
        #expect(try await storage.unlock(code: "4444") == everyday)
        #expect(try await storage.unlock(code: "top-code") == top)
        #expect(try await storage.unlock(code: "dots-1-5-9") != nil)

        // On in the top as well: the top is the one reset, the child sits under it.
        try await storage.setResetWithRecoveryKey(true, for: top)
        await storage.lockAll()
        #expect(try await storage.resetCode(to: "top-2", with: key) == top)
        #expect(try await storage.unlock(code: "top-2") == top)
        #expect(try await storage.unlock(code: "4444") == everyday)

        // After a new key from the child, each set of words resets its own space.
        let new = RecoveryKey()
        let child = try #require(try await storage.unlock(code: "4444"))
        try await storage.setRecoveryKey(new, from: child)
        await storage.lockAll()
        #expect(try await storage.resetCode(to: "5555", with: new) == everyday)
        #expect(try await storage.resetCode(to: "top-3", with: key) == top)
        await #expect(throws: BackupError.cannotReset) {
            _ = try await storage.resetCode(to: "6666", with: RecoveryKey())
        }
        await storage.lockAll()
        #expect(try await storage.unlock(code: "5555") == everyday)
        #expect(try await storage.unlock(code: "top-3") == top)
    }

    @Test func statusNoteIsShownOnce() {
        BackupStatus.current = BackupStatus(pendingNote: "The last backup didn't finish. See Settings.")
        #expect(BackupStatus.takeNote() == "The last backup didn't finish. See Settings.")
        #expect(BackupStatus.takeNote() == nil)
        #expect(BackupSchedule.off.interval == nil)
        // Off until the person says yes.
        UserDefaults.standard.removeObject(forKey: BackupStatus.scheduleKey)
        #expect(BackupStatus.schedule == .off)
        #expect(BackupStatus.notAskedYet)
    }

    @Test func restorationContinuesAfterReopenWithoutReplacingData() async throws {
        let key = RecoveryKey()
        let original = try await makeStorage(key: key)
        let backup = tempURL(), output = tempURL()
        defer {
            for url in [original.url, backup, output] { try? FileManager.default.removeItem(at: url) }
        }
        try await original.writeBackup(to: backup)
        let first = try ReservedStorage.restore(backup: backup, recoveryKey: key, to: output, stretcher: PBKDF2Stretcher(iterations: 1000))
        await first.setCodeWrapIterations(1000)
        let everyday = try #require(try await first.adopt(code: "2580", recoveryKey: key))
        try await first.writeFile(named: "new", data: Data("keep newer data".utf8), in: everyday)
        await first.lockAll()
        let again = try ReservedStorage.open(at: output, stretcher: PBKDF2Stretcher(iterations: 1000), access: .free)
        await again.setCodeWrapIterations(1000)
        let top = try #require(try await again.adopt(code: "top-code", recoveryKey: key))
        #expect(try await again.readFile(named: "t", in: top) == Data("top".utf8))
        let child = try #require(try await again.unlock(code: "2580"))
        #expect(try await again.readFile(named: "new", in: child) == Data("keep newer data".utf8))
    }

    @Test func adoptionCannotGiveTwoSpacesTheSameDeviceCode() async throws {
        let key = RecoveryKey()
        let original = try await makeStorage(key: key)
        let backup = tempURL()
        defer { try? FileManager.default.removeItem(at: original.url); try? FileManager.default.removeItem(at: backup) }
        try await original.writeBackup(to: backup)
        let recovered = try await restored(backup, with: key)
        defer { try? FileManager.default.removeItem(at: recovered.url) }
        let everyday = try #require(try await recovered.adopt(code: "2580", recoveryKey: key))
        try await recovered.setCode("top-code", for: everyday)
        await #expect(throws: StorageError.codeInUse) { try await recovered.adopt(code: "top-code", recoveryKey: key) }
        try await recovered.setCode("different", for: everyday)
        #expect(try await recovered.adopt(code: "top-code", recoveryKey: key) != nil)
    }
}
