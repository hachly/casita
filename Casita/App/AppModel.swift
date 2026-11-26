import Foundation
import LocalAuthentication
import Observation
import Security

/// App-wide state: the one storage file, which space (if any) is open, and
/// the wrong-code waits. Nothing here is per space.
@MainActor @Observable
final class AppModel: EntryController {
    enum Phase: Equatable {
        case loading
        case firstRun
        case locked
        case open(SpaceRef)
    }

    private(set) var phase: Phase = .loading
    private(set) var storage: ReservedStorage?
    /// Set while a code is being checked, so the UI shows the same waiting
    /// state for every attempt.
    private(set) var checking = false
    /// App-wide; Settings changes it and `LockSettingsStore` keeps it.
    var lockSettings = LockSettingsStore.standard.load() {
        didSet { LockSettingsStore.standard.save(lockSettings) }
    }
    let waits = WrongCodeWaits()
    var hideDotsLine: Bool { lockSettings.hideDotsLine }
    var haptics: Bool { lockSettings.haptics }

    static var storageURL: URL { AppGroup.storageURL }

    #if DEBUG
    /// End-to-end tests of restore. With `-devCodes`, `-devRecoveryWords`
    /// seals the spaces to the dev sentence (`RecoveryPhrase.dev`) and
    /// `-devWriteBackup` writes a backup to `devBackupURL`, which survives
    /// `-freshStart`; `RestoreFlow` picks it with `-devBackupFile`.
    static let devBackupURL = FileManager.default.temporaryDirectory.appendingPathComponent("e2e.casitabackup")

    static func devBackupIfAsked(_ storage: ReservedStorage?, top: SpaceRef) async throws {
        let args = ProcessInfo.processInfo.arguments
        guard let storage, args.contains("-devRecoveryWords") else { return }
        try await storage.setRecoveryKey(RecoveryKey(phrase: .dev), from: top)
        if args.contains("-devResetSwitch") { try await storage.setResetWithRecoveryKey(true, for: top) }
        if args.contains("-devWriteBackup") {
            try? FileManager.default.removeItem(at: devBackupURL)
            try await storage.writeBackup(to: devBackupURL)
        }
    }

    /// End-to-end tests (`-freshStart`): start from nothing, like a new
    /// install. Runs first thing at launch, before RevenueCat starts, so its
    /// anonymous ID goes too and every run begins without a plan.
    static func freshStartIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-freshStart") else { return }
        try? FileManager.default.removeItem(at: storageURL)
        try? FileManager.default.removeItem(at: partialStorageURL)
        EverydayCredentialStore.delete()
        WrongCodeWaits().reset()
        for key in LockSettingsStore.Key.all { AppGroup.defaults.removeObject(forKey: key) }
        AppGroup.defaults.removeObject(forKey: lastCodeKey)
        // `-devStaleCode`: the last code was a month ago, so the reminder shows.
        if ProcessInfo.processInfo.arguments.contains("-devStaleCode") {
            AppGroup.defaults.set(Date.now.addingTimeInterval(-30 * 86_400), forKey: lastCodeKey)
        }
        AppGroup.defaults.removeObject(forKey: AppGroup.ownsPlanKey)
        AppGroup.defaults.removeObject(forKey: SpaceView.tipClosedKey)
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        // RevenueCat keeps its anonymous ID and cached purchases in its own suite.
        UserDefaults(suiteName: "com.revenuecat.user_defaults")?.removePersistentDomain(forName: "com.revenuecat.user_defaults")
    }
    #endif

    func start() {
        guard phase == .loading else { return }
        AppGroup.migrateLegacyStorage()
        if let storage = try? ReservedStorage.open(at: Self.storageURL, stretcher: .default, access: .purchases) {
            self.storage = storage
            BackupScheduler.shared.storage = storage
            BackupScheduler.shared.schedule()
            phase = .locked
        } else if let codes = Self.devCodes {
            // Development only: `-devCodes everyday,private` skips onboarding.
            Task {
                do {
                    let spaces = try await createFirstSpaces(privateCode: codes.private, everydayCode: codes.everyday, useFaceID: false, size: .mb512)
                    #if DEBUG
                    try await Self.devBackupIfAsked(storage, top: spaces.top)
                    // `-devFullFreeSpace` fills the everyday space to the free
                    // allowance; `-devFreeItems N` puts N items in it.
                    let args = ProcessInfo.processInfo.arguments
                    let fill = args.contains("-devFullFreeSpace") ? FreePlan.itemLimit
                        : args.firstIndex(of: "-devFreeItems").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
                    if let fill, let storage {
                        for index in 0..<fill {
                            try await storage.writeFile(named: "Item \(index).txt", data: Data("Test item".utf8), in: spaces.everyday)
                        }
                    }
                    #endif
                    _ = spaces
                    finishFirstRun()
                } catch {
                    phase = .firstRun
                }
            }
        } else if FileManager.default.fileExists(atPath: Self.storageURL.path) {
            // The file is there but can't be read yet (launched while the
            // phone is locked). Never fall into first run over an existing file.
            phase = .locked
        } else {
            phase = .firstRun
        }
    }

    /// Opens the storage if `start()` could not.
    private func reopenIfNeeded() -> ReservedStorage? {
        if let storage { return storage }
        guard let opened = try? ReservedStorage.open(at: Self.storageURL, stretcher: .default, access: .purchases) else { return nil }
        storage = opened
        BackupScheduler.shared.storage = opened
        BackupScheduler.shared.schedule()
        return opened
    }

    /// Available on every entry screen, whether or not this is a restored
    /// installation. Reveals nothing about unadopted spaces.
    func storageForRecovery() -> ReservedStorage? { reopenIfNeeded() }

    private static var devCodes: (everyday: String, private: String)? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-devCodes"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: ",").map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
        #else
        return nil
        #endif
    }

    /// Where the storage file is built before it moves to `storageURL`.
    static var partialStorageURL: URL {
        storageURL.deletingLastPathComponent().appendingPathComponent("reserved.partial")
    }

    /// The two spaces onboarding makes, both still open.
    struct FirstSpaces: Equatable, Sendable {
        let top: SpaceRef
        let everyday: SpaceRef
    }

    /// Makes the storage at `size` with the top space and, under it, the
    /// everyday space, which gets half the room. Both stay open for the rest
    /// of onboarding and the phase stays `.firstRun`; `finishFirstRun()`
    /// locks them and shows the entry screen. If the app dies after this
    /// returns, the next launch finds whole storage and shows the entry screen.
    @discardableResult
    func createFirstSpaces(privateCode: String, everydayCode: String, useFaceID: Bool, size: StorageSize) async throws -> FirstSpaces {
        let (storage, top, everyday) = try await Self.buildFirstSpaces(
            at: Self.storageURL, partial: Self.partialStorageURL, bytes: size.rawValue,
            privateCode: privateCode, everydayCode: everydayCode, stretcher: .default, access: .purchases
        )
        if useFaceID {
            // A failed Keychain write only means Face ID won't open it; the
            // code still does, so setup carries on.
            try? EverydayCredentialStore.save(everyday)
        }
        let spaces = FirstSpaces(top: try await storage.open(top), everyday: try await storage.open(everyday))
        self.storage = storage
        BackupScheduler.shared.storage = storage
        return spaces
    }

    /// Rebuilds the storage from a backup on a phone that has none yet.
    /// Writes to the partial file and moves it into place only once it
    /// opens, so a failure never leaves a half-made file where the entry
    /// screen would find it. Spaces come back one code at a time with
    /// `adopt(code:recoveryKey:)`; `finishFirstRun()` then locks them.
    func restore(backup: URL, key: RecoveryKey) async throws -> ReservedStorage {
        let partial = Self.partialStorageURL, url = Self.storageURL
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: partial)
            let scoped = backup.startAccessingSecurityScopedResource()
            defer { if scoped { backup.stopAccessingSecurityScopedResource() } }
            // Coordinated, so a backup still in iCloud downloads first.
            var coordinatorError: NSError?
            var restoreError: (any Error)?
            NSFileCoordinator().coordinate(readingItemAt: backup, options: [], error: &coordinatorError) { readable in
                do { _ = try ReservedStorage.restore(backup: readable, recoveryKey: key, to: partial, stretcher: .default) } catch { restoreError = error }
            }
            if let restoreError { try? FileManager.default.removeItem(at: partial); throw restoreError }
            if let coordinatorError { try? FileManager.default.removeItem(at: partial); throw coordinatorError }
            try FileManager.default.moveItem(at: partial, to: url)
        }.value
        let storage = try ReservedStorage.open(at: url, stretcher: .default, access: .purchases)
        self.storage = storage
        BackupScheduler.shared.storage = storage
        return storage
    }

    /// Ends first run: locks every space, then opens `space` if given (the
    /// everyday space after setup, which just typed its code), else shows
    /// the entry screen. If Casita locked meanwhile, the entry screen.
    func finishFirstRun(opening space: SpaceRef? = nil) {
        guard phase == .firstRun || phase == .loading, !finishing, let storage else { return }
        // Setup typed both codes just now; a date already there is kept.
        if AppGroup.defaults.object(forKey: Self.lastCodeKey) == nil {
            AppGroup.defaults.set(Date.now, forKey: Self.lastCodeKey)
        }
        BackupScheduler.shared.schedule()
        guard let space else {
            phase = .locked
            Task { await storage.lockAll() }
            return
        }
        finishing = true
        let locksBefore = locks
        Task {
            // Every key setup held goes; the space shown comes back from its
            // credential, as Face ID opens it.
            let credential = try? await storage.credential(for: space)
            await storage.lockAll()
            if let credential, let ref = try? await storage.open(credential) {
                await openUnlessLocked(ref, since: locksBefore)
            }
            // Locked meanwhile, or the space didn't open: the entry screen.
            if case .open = phase {} else { phase = .locked }
            finishing = false
        }
    }

    /// Set while setup's last step opens the first space, so a second tap
    /// can't start another.
    private var finishing = false

    /// Builds the storage file under `partial` and moves it to `url` only
    /// once both spaces exist, so `url` never holds a file whose codes don't
    /// open anything. Never replaces a file already at `url`. Returns the
    /// storage opened at `url`, all spaces locked, with credentials to
    /// reopen the two spaces without stretching their codes again.
    nonisolated static func buildFirstSpaces(
        at url: URL, partial: URL, bytes: Int64, privateCode: String, everydayCode: String, stretcher: any CodeStretcher, access: StorageAccess = .unrestricted
    ) async throws -> (storage: ReservedStorage, top: SpaceCredential, everyday: SpaceCredential) {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw FirstRunError.storageExists }
        try? FileManager.default.removeItem(at: partial)
        let topCredential: SpaceCredential
        let everydayCredential: SpaceCredential
        do {
            let built = try await Task.detached(priority: .userInitiated) {
                try ReservedStorage.create(at: partial, bytes: bytes, stretcher: stretcher)
            }.value
            let top = try await built.createTopSpace(code: privateCode)
            let free = try await built.freeBytes(in: top)
            let everydayChunks = Int(free / Int64(ReservedStorage.chunkPlain)) / 2
            let everyday = try await built.createChild(of: top, name: "Everyday", code: everydayCode, chunks: everydayChunks)
            topCredential = try await built.credential(for: top)
            everydayCredential = try await built.credential(for: everyday)
            await built.lockAll()
            try FileManager.default.moveItem(at: partial, to: url)
        } catch {
            // Give the space back; nothing at `partial` is ever opened.
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        let storage = try ReservedStorage.open(at: url, stretcher: stretcher, access: access)
        return (storage, topCredential, everydayCredential)
    }

    /// Checks a code. Returns false for a wrong code or during a wait. Every
    /// call takes at least the storage's minimum unlock duration.
    func submit(code: String) async -> Bool {
        guard let storage = reopenIfNeeded(), !checking else { return false }
        if waits.isWaiting { return false }
        checking = true
        defer { checking = false }
        let locksBefore = locks
        let opened = try? await storage.unlock(code: code)
        guard let ref = opened ?? nil else {
            waits.registerWrongAttempt()
            return false
        }
        AppGroup.defaults.set(Date.now, forKey: Self.lastCodeKey)
        await openUnlessLocked(ref, since: locksBefore)
        return true
    }

    // MARK: Forgot code, reminder

    /// Shows the "Forgot code?" sheet from the entry screen.
    var forgotCodeShown = false
    var offersForgotCode: Bool { true }
    func forgotCode() { forgotCodeShown = true }

    /// When a code (not Face ID) last opened a space. App-wide, like every
    /// setting seen from outside a space.
    static let lastCodeKey = "lastCodeUnlock"
    static let reminderDays: Double = 14

    var reminder: String? {
        guard let last = AppGroup.defaults.object(forKey: Self.lastCodeKey) as? Date,
              Date.now.timeIntervalSince(last) > Self.reminderDays * 86_400 else { return nil }
        return "Still remember your code? Type it to check."
    }

    /// Gives a space a new code with the recovery sentence, when that
    /// space's reset switch is on. Locks everything again afterwards.
    func resetCode(phrase: String, newCode: String) async throws {
        guard let storage = reopenIfNeeded() else { throw CocoaError(.fileNoSuchFile) }
        let key = try await RecoveryKey.typed(phrase)
        _ = try await storage.resetCode(to: newCode, with: key)
        await storage.lockAll()
    }

    /// Face ID opens the everyday space and nothing else.
    func unlockWithFaceID() async -> FaceIDResult {
        guard let storage = reopenIfNeeded() else { return .failed }
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .notSetUp
        }
        let locksBefore = locks
        guard let credential = try? await EverydayCredentialStore.load() else { return .failed }
        guard let ref = try? await storage.open(credential) else {
            // The everyday space is gone (deleted); the entry is stale.
            EverydayCredentialStore.delete()
            return .notSetUp
        }
        await openUnlessLocked(ref, since: locksBefore)
        return .opened
    }

    /// Opens a space under the open one without its code, and closes the
    /// parent, so its keys don't stay in memory behind the child.
    func switchTo(_ name: String, under parent: SpaceRef) async throws {
        guard let storage else { return }
        let locksBefore = locks
        let child = try await storage.openChild(of: parent, named: name)
        await storage.lock(parent)
        await openUnlessLocked(child, since: locksBefore)
    }

    /// Opening takes a moment (a code check pads to a full second). If
    /// Casita locked meanwhile, say because the owner left the app, the
    /// space stays shut.
    private func openUnlessLocked(_ ref: SpaceRef, since locksBefore: Int) async {
        guard locks == locksBefore else {
            await storage?.lock(ref)
            return
        }
        phase = .open(ref)
        RatingPrompt.spaceOpened()
        heartbeat()
        place = Place()
        resumeTo = nil
        Task { await takeRecentPlace(of: ref) }
    }

    // MARK: Reopen where I was

    /// Where the open space is, kept current by its screens: the feature,
    /// and in Web the page that is open (never an Incognito one).
    struct Place: Codable, Equatable, Sendable {
        var feature: String?
        var webURL: URL?
    }

    /// Written into the space as it locks, so only that space's code can
    /// read it, and nothing outside the space says where anyone was.
    private struct Left: Codable {
        var place: Place
        var lockedAt: Date
    }

    static let placeFile = "app/place.json"
    var place = Place()
    /// Set as a space opens when it was locked less than
    /// `lockSettings.reopenMinutes` ago. Its screens go there and clear it.
    var resumeTo: Place?

    private func takeRecentPlace(of ref: SpaceRef) async {
        let minutes = lockSettings.reopenMinutes
        guard minutes > 0, let storage,
              let data = try? await storage.readFile(named: Self.placeFile, in: ref),
              let left = try? JSONDecoder().decode(Left.self, from: data), left.place.feature != nil
        else { return }
        let age = Date.now.timeIntervalSince(left.lockedAt)
        guard age >= 0, age < Double(minutes) * 60, case .open(let current) = phase, current == ref else { return }
        resumeTo = left.place
    }

    /// Tells Save to Casita a space is open here (see `AppGroup.spaceOpenKey`).
    func heartbeat() {
        guard case .open = phase else { return }
        AppGroup.defaults.set(Date.now, forKey: AppGroup.spaceOpenKey)
    }

    /// Screens that keep the idle lock away while they work: a system picker
    /// whose touches never reach Casita, an import, a backup, a playing
    /// video. Leaving the app still locks at once, and every lock clears
    /// them, so a hold that never ended can't keep the idle lock off.
    var idleHolds: Set<UUID> = []

    /// True on a phone with a hinge (iPhone Duo), so Settings offers "Lock
    /// when closed". Told by `LockGuard`; nothing stores it.
    var hasHinge = false

    /// Counts every lock, so an open that was in flight can tell.
    private var locks = 0

    /// Writes into the open space that must land before it locks (web
    /// logins saved as Casita leaves the screen).
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    /// Runs `work` now; a lock meanwhile waits up to 3 s for it before the
    /// space's keys go. The screen locks at once either way.
    func whileSaving(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pendingSaves[id] = Task { @MainActor in
            await work()
            self.pendingSaves[id] = nil
        }
    }

    func lock() {
        locks += 1
        idleHolds.removeAll()
        AppGroup.defaults.removeObject(forKey: AppGroup.spaceOpenKey)
        guard case .open(let ref) = phase, let storage else { return }
        phase = .locked
        let pending = Array(pendingSaves.values)
        let left = try? JSONEncoder().encode(Left(place: place, lockedAt: .now))
        Task {
            if !pending.isEmpty {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for save in pending { await save.value } }
                    group.addTask { try? await Task.sleep(for: .seconds(3)) }
                    await group.next()
                    group.cancelAll()
                }
            }
            if let left { try? await storage.writeFile(named: Self.placeFile, data: left, in: ref) }
            await storage.lockAll()
            // No unlocked copy outlives the space it came from.
            MediaTemp.sweep(keepingBackups: true)
        }
    }

    /// Erases every space and returns to first run. Reached by holding the
    /// Face ID key; the only way back after the top space was deleted.
    func startOver() {
        let storage = self.storage
        self.storage = nil
        BackupScheduler.shared.storage = nil
        Task {
            await storage?.lockAll()
            try? FileManager.default.removeItem(at: Self.storageURL)
            EverydayCredentialStore.delete()
            waits.reset()
            AppGroup.defaults.removeObject(forKey: Self.lastCodeKey)
            AppGroup.defaults.removeObject(forKey: SpaceView.tipClosedKey)
            // Setup again: backups are asked about again.
            UserDefaults.standard.removeObject(forKey: BackupStatus.scheduleKey)
            phase = .firstRun
        }
    }
}

enum FirstRunError: Error {
    /// A storage file is already in place; first run never replaces one.
    case storageExists
}
