import CryptoKit
import Foundation
import Testing
@testable import Casita

/// A UserDefaults of its own, removed when the test ends.
private final class ScratchDefaults {
    let name = "casita.settings.\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: name)!
    deinit { UserDefaults().removePersistentDomain(forName: name) }
}

@Suite struct LockSettingsStoreTests {
    @Test func defaultsNeedNoSetup() {
        let scratch = ScratchDefaults()
        let settings = LockSettingsStore(defaults: scratch.defaults).load()
        #expect(settings == LockSettings())
        #expect(settings.idleSeconds == 60)
        #expect(settings.gesture == .flip)
        #expect(settings.hideDotsLine == false)
        #expect(settings.haptics == true)
        #expect(settings.lockWhenClosed == false)
        #expect(LockSettings.idleChoices == [30, 60, 300])
        #expect(LockSettings.Gesture.allCases == [.flip, .twoFingerDoubleTap, .off])
    }

    @Test func everyChoicePersistsAcrossLaunches() {
        let scratch = ScratchDefaults()
        for idle in LockSettings.idleChoices {
            for gesture in LockSettings.Gesture.allCases {
                for flag in [true, false] {
                    let settings = LockSettings(idleSeconds: idle, gesture: gesture, hideDotsLine: flag, haptics: !flag, lockWhenClosed: flag)
                    LockSettingsStore(defaults: scratch.defaults).save(settings)
                    // A fresh store on the same defaults stands in for a relaunch.
                    #expect(LockSettingsStore(defaults: scratch.defaults).load() == settings)
                }
            }
        }
    }

    @Test func unknownValuesFallBackToDefaults() {
        let scratch = ScratchDefaults()
        scratch.defaults.set(45, forKey: LockSettingsStore.Key.idleSeconds)
        scratch.defaults.set("shake", forKey: LockSettingsStore.Key.gesture)
        scratch.defaults.set("yes", forKey: LockSettingsStore.Key.haptics)
        #expect(LockSettingsStore(defaults: scratch.defaults).load() == LockSettings())
    }

    /// One fixed set of keys for the whole app: saving writes exactly these,
    /// with nothing that names or numbers a space.
    @Test func oneSetOfKeysForEverySpace() {
        let scratch = ScratchDefaults()
        let before = Set(scratch.defaults.dictionaryRepresentation().keys)
        var settings = LockSettings()
        settings.gesture = .off
        LockSettingsStore(defaults: scratch.defaults).save(settings)
        let added = Set(scratch.defaults.dictionaryRepresentation().keys).subtracting(before)
        #expect(added == Set(LockSettingsStore.Key.all))
        #expect(LockSettingsStore.Key.all == ["lock.idleSeconds", "lock.gesture", "lock.hideDotsLine", "lock.haptics", "lock.reopenMinutes", "lock.whenClosed"])
    }

    /// The app reads and writes lock settings through the store.
    @MainActor @Test func appModelPersistsLockSettings() {
        let store = LockSettingsStore.standard
        let original = store.load()
        defer { store.save(original) }

        let model = AppModel()
        #expect(model.lockSettings == original)
        model.lockSettings.idleSeconds = original.idleSeconds == 300 ? 30 : 300
        model.lockSettings.haptics.toggle()
        #expect(store.load() == model.lockSettings)
        #expect(AppModel().lockSettings == model.lockSettings)
    }
}

// MARK: - Settings view model

private let testBytes = Int64(ReservedStorage.chunksOffset + 40 * ReservedStorage.chunkSealed)

private struct Tree {
    let storage: ReservedStorage
    let top: SpaceRef
    let everyday: SpaceRef
    let deep: SpaceRef
    static let codes = (top: "top-code", everyday: "2580", deep: "dots:0-4-8-5")
}

/// A top space, an everyday space under it and one more under that.
private func makeTree() async throws -> Tree {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("casita-\(UUID().uuidString).bin")
    let storage = try ReservedStorage.create(at: url, bytes: testBytes, stretcher: PBKDF2Stretcher(iterations: 1000))
    await storage.setMinimumUnlockDuration(.milliseconds(1))
    await storage.setCodeWrapIterations(1000)
    let top = try await storage.createTopSpace(code: Tree.codes.top)
    let everyday = try await storage.createChild(of: top, name: "Everyday", code: Tree.codes.everyday, chunks: 10)
    let deep = try await storage.createChild(of: everyday, name: "Deep", code: Tree.codes.deep, chunks: 3)
    return Tree(storage: storage, top: top, everyday: everyday, deep: deep)
}

/// Type names and property labels reachable from `value`, without going into
/// the shared storage (which holds every open space by design) or into
/// Observation's bookkeeping.
private func reachable(_ value: Any, depth: Int = 0) -> (types: [String], labels: [String]) {
    guard depth < 8, !(value is ReservedStorage) else { return ([], []) }
    var types = [String(describing: type(of: value))]
    var labels: [String] = []
    for child in Mirror(reflecting: value).children where child.label != "_$observationRegistrar" {
        if let label = child.label { labels.append(label) }
        let inner = reachable(child.value, depth: depth + 1)
        types += inner.types
        labels += inner.labels
    }
    return (types, labels)
}

private func expectNothingAboutASpace(_ settings: SettingsModel) {
    let found = reachable(settings)
    // The walk really sees the model's properties, and would see a space.
    #expect(found.labels.contains("_reservedBytes") && found.labels.contains("_backup"))
    #expect(reachable([Optional(SpaceRef(slot: 3))]).types.contains { $0.contains("SpaceRef") })

    for name in ["SpaceRef", "SpaceHeader", "ChildRef", "SpaceState", "SpaceCredential"] {
        #expect(!found.types.contains { $0.contains(name) }, "Settings holds a \(name)")
    }
    for label in found.labels {
        #expect(!label.lowercased().contains("space") && !label.lowercased().contains("slot"), "Settings holds \(label)")
    }
}

@MainActor @Suite struct SettingsModelTests {
    /// Opening Settings from any space gives the same screen state, and
    /// using the per-space buttons leaves nothing about that space behind.
    @Test func sameInEverySpace() async throws {
        let tree = try await makeTree()
        defer { try? FileManager.default.removeItem(at: tree.storage.url) }

        var snapshots: [SettingsModel.Snapshot] = []
        for (space, code) in [(tree.top, Tree.codes.top), (tree.everyday, Tree.codes.everyday), (tree.deep, Tree.codes.deep)] {
            await tree.storage.lockAll()
            #expect(try await tree.storage.unlock(code: code) == space)
            let settings = SettingsModel(storage: tree.storage)
            await settings.refresh()
            expectNothingAboutASpace(settings)

            _ = await settings.freeRoom(in: space)
            _ = await settings.spaceCount(under: space)
            _ = await settings.resetIsOn(in: space)
            try await settings.changeCode(to: code, for: space)
            await settings.refresh()
            expectNothingAboutASpace(settings)
            snapshots.append(settings.snapshot)
        }
        #expect(Set(snapshots.map(\.reservedBytes)).count == 1)
        #expect(snapshots.allSatisfy { $0 == snapshots[0] })
    }

    @Test func countsOnlyTheSpacesUnderThisOne() async throws {
        let tree = try await makeTree()
        defer { try? FileManager.default.removeItem(at: tree.storage.url) }
        let settings = SettingsModel(storage: tree.storage)
        #expect(await settings.spaceCount(under: tree.top) == 2)
        #expect(await settings.spaceCount(under: tree.everyday) == 1)
        #expect(await settings.spaceCount(under: tree.deep) == 0)
        #expect(DeleteThisSpaceSheet.warning(spacesUnder: 0) == "This deletes this space and everything in it.")
        #expect(DeleteThisSpaceSheet.warning(spacesUnder: 2).contains("the 2 spaces under it"))
    }

    @Test func changeCodeRefusesCodesInUse() async throws {
        let tree = try await makeTree()
        defer { try? FileManager.default.removeItem(at: tree.storage.url) }
        let settings = SettingsModel(storage: tree.storage)

        await #expect(throws: StorageError.codeInUse) {
            try await settings.changeCode(to: Tree.codes.top, for: tree.everyday)
        }
        try await settings.changeCode(to: "135790", for: tree.everyday)
        await tree.storage.lockAll()
        #expect(try await tree.storage.unlock(code: "135790") == tree.everyday)
        #expect(try await tree.storage.unlock(code: Tree.codes.everyday) == nil)
        #expect(try await tree.storage.unlock(code: Tree.codes.top) == tree.top)
    }

    /// Only this space's own code deletes it. Another space's code gets the
    /// same answer as a wrong one, and deleting takes the spaces under it.
    @Test func deleteNeedsThisSpacesCode() async throws {
        let tree = try await makeTree()
        defer { try? FileManager.default.removeItem(at: tree.storage.url) }
        let settings = SettingsModel(storage: tree.storage)

        #expect(try await settings.delete(tree.everyday, confirmingWith: "0000") == false)
        #expect(try await settings.delete(tree.everyday, confirmingWith: Tree.codes.top) == false)
        #expect(try await settings.delete(tree.everyday, confirmingWith: Tree.codes.deep) == false)
        #expect(try await tree.storage.fileNames(in: tree.everyday).isEmpty)

        #expect(try await settings.delete(tree.everyday, confirmingWith: Tree.codes.everyday))
        await tree.storage.lockAll()
        #expect(try await tree.storage.unlock(code: Tree.codes.everyday) == nil)
        #expect(try await tree.storage.unlock(code: Tree.codes.deep) == nil)
        #expect(try await tree.storage.unlock(code: Tree.codes.top) == tree.top)
        #expect(try await tree.storage.children(of: tree.top).isEmpty)
    }

    @Test func resetSwitchIsOffByDefaultAndPerSpace() async throws {
        let tree = try await makeTree()
        defer { try? FileManager.default.removeItem(at: tree.storage.url) }
        let settings = SettingsModel(storage: tree.storage)
        for space in [tree.top, tree.everyday, tree.deep] {
            #expect(await settings.resetIsOn(in: space) == false)
        }
        try await settings.setReset(true, for: tree.top)
        #expect(await settings.resetIsOn(in: tree.top))
        #expect(await settings.resetIsOn(in: tree.everyday) == false)
        try await settings.setReset(false, for: tree.top)
        #expect(await settings.resetIsOn(in: tree.top) == false)
    }

    @Test func newRecoveryKeyIsWrittenToTheFile() async throws {
        let tree = try await makeTree()
        defer { try? FileManager.default.removeItem(at: tree.storage.url) }
        let settings = SettingsModel(storage: tree.storage)
        let key = RecoveryKey()
        try await settings.setRecoveryKey(key, from: tree.top)
        // Each space's portable slot starts with its slot's key from the new words.
        let file = try Data(contentsOf: tree.storage.url)
        for space in [tree.top, tree.everyday, tree.deep] {
            let offset = Int(ReservedStorage.portableOffset(space.slot))
            #expect(file[offset..<offset + 32] == key.publicKey(forSlot: space.slot).rawRepresentation)
        }
    }

    @Test func makeMoreRoomStopsAtTheLargestSize() {
        let stops = StorageSize.allCases
        for (size, next) in zip(stops, stops.dropFirst()) {
            #expect(SettingsModel.nextSize(after: size.rawValue) == next)
        }
        #expect(SettingsModel.nextSize(after: StorageSize.gb128.rawValue) == nil)
        #expect(SettingsModel.nextSize(after: testBytes) == nil)
        #expect(stops.map(\.label) == ["512 MB", "1 GB", "2 GB", "4 GB", "8 GB", "16 GB", "32 GB", "64 GB", "128 GB"])
        #expect(SettingsModel.sizeLabel(StorageSize.gb2.rawValue) == "2 GB")
    }

    @Test func growingGivesTheNewRoomToThisSpace() async throws {
        let tree = try await makeTree()
        defer { try? FileManager.default.removeItem(at: tree.storage.url) }
        let settings = SettingsModel(storage: tree.storage)
        let before = try #require(await settings.freeRoom(in: tree.deep))
        let topBefore = try #require(await settings.freeRoom(in: tree.top))
        try await tree.storage.grow(for: tree.deep, toBytes: testBytes + 4 * Int64(ReservedStorage.chunkSealed))
        await settings.refresh()
        #expect(settings.reservedBytes == testBytes + 4 * Int64(ReservedStorage.chunkSealed))
        #expect(await settings.freeRoom(in: tree.deep) == before + 4 * Int64(ReservedStorage.chunkPlain))
        #expect(await settings.freeRoom(in: tree.top) == topBefore)
    }
}
