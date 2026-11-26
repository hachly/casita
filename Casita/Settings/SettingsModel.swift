import Foundation
import Observation

/// What the Settings screen shows, and what its buttons do.
///
/// Everything this model holds is app-wide, so Settings is the same in every
/// space. It never stores which space is open: per-space actions take the
/// space as an argument and keep nothing about it afterwards.
@MainActor @Observable
final class SettingsModel {
    let storage: ReservedStorage
    private(set) var reservedBytes: Int64 = 0
    private(set) var schedule: BackupSchedule
    private(set) var backup: BackupStatus
    private(set) var growing = false

    init(storage: ReservedStorage) {
        self.storage = storage
        schedule = BackupStatus.schedule
        backup = BackupStatus.current
    }

    /// Everything the screen shows that isn't about the open space.
    struct Snapshot: Equatable {
        var reservedBytes: Int64
        var schedule: BackupSchedule
        var backup: BackupStatus
        var growing: Bool
    }

    var snapshot: Snapshot {
        Snapshot(reservedBytes: reservedBytes, schedule: schedule, backup: backup, growing: growing)
    }

    func refresh() async {
        await BackupScheduler.shared.refreshUploadStatus()
        reservedBytes = await storage.byteSize
        schedule = BackupStatus.schedule
        backup = BackupStatus.current
    }

    // MARK: Storage

    /// The stop "Make more room" grows to; nil at the largest size.
    var nextSize: StorageSize? { Self.nextSize(after: reservedBytes) }

    static func nextSize(after bytes: Int64) -> StorageSize? {
        StorageSize(rawValue: bytes)?.next
    }

    static func sizeLabel(_ bytes: Int64) -> String {
        if let size = StorageSize(rawValue: bytes) { return size.label }
        return bytes.formatted(.byteCount(style: .memory))
    }

    /// Free bytes on the iPhone where the reserved storage lives.
    var iPhoneFreeBytes: Int64? {
        let folder = storage.url.deletingLastPathComponent()
        return try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Room the iPhone keeps for itself on top of what growing takes.
    static let iPhoneMargin: Int64 = 1 << 30

    /// True when the iPhone has room for the next stop.
    var iPhoneHasRoomToGrow: Bool {
        guard let next = nextSize else { return false }
        guard let free = iPhoneFreeBytes else { return true }
        return free >= next.rawValue - reservedBytes + Self.iPhoneMargin
    }

    /// Grows the reserved storage to the next stop; the new room goes to `space`.
    func makeMoreRoom(for space: SpaceRef) async throws {
        growing = true
        defer { growing = false }
        try await storage.grow(for: space)
        await refresh()
    }

    // MARK: Backup

    func setSchedule(_ new: BackupSchedule) {
        BackupStatus.schedule = new
        schedule = new
        BackupScheduler.shared.schedule()
    }

    // MARK: The open space (passed in, never kept)

    func freeRoom(in space: SpaceRef) async -> Int64? {
        try? await storage.freeBytes(in: space)
    }

    func spaceCount(under space: SpaceRef) async -> Int {
        (try? await storage.spaceCount(under: space)) ?? 0
    }

    func resetIsOn(in space: SpaceRef) async -> Bool {
        (try? await storage.resetsWithRecoveryKey(space)) ?? false
    }

    func setReset(_ on: Bool, for space: SpaceRef) async throws {
        try await storage.setResetWithRecoveryKey(on, for: space)
    }

    /// Re-seals this space and every space under it to the new words.
    func setRecoveryKey(_ key: RecoveryKey, from space: SpaceRef) async throws {
        try await storage.setRecoveryKey(key, from: space)
    }

    /// Throws `StorageError.codeInUse` when another space already has `code`.
    func changeCode(to code: String, for space: SpaceRef) async throws {
        try await storage.setCode(code, for: space)
    }

    /// Deletes `space` and every space under it when `code` is its own code.
    /// A wrong code and another space's code give the same answer, false,
    /// after the same full unlock time.
    func delete(_ space: SpaceRef, confirmingWith code: String) async throws -> Bool {
        let opened = try await storage.unlock(code: code)
        guard opened == space else {
            if let opened { await storage.lock(opened) }
            return false
        }
        try await storage.deleteSelf(space)
        return true
    }
}

extension StorageSize {
    var label: String {
        rawValue < StorageSize.gb1.rawValue ? "\(rawValue >> 20) MB" : "\(rawValue >> 30) GB"
    }
}

extension BackupSchedule {
    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .off: "Off"
        }
    }
}
