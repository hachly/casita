import BackgroundTasks
import Foundation
import Network
import UIKit

enum BackupSchedule: String, CaseIterable, Sendable {
    case daily, weekly, monthly, off

    var interval: TimeInterval? {
        switch self {
        case .daily: 86_400
        case .weekly: 7 * 86_400
        case .monthly: 30 * 86_400
        case .off: nil
        }
    }
}

/// What Settings shows about backups. Stored in UserDefaults; nothing in it
/// says what is inside the storage. No notifications, ever.
struct BackupStatus: Codable, Equatable, Sendable {
    var lastSuccess: Date?
    var lastFailure: Date?
    var lastFailureMessage: String?
    /// Set by a failed automatic backup, cleared by `BackupStatus.takeNote()`;
    /// the next space to open shows it as one line.
    var pendingNote: String?
    var lastPrepared: Date?
    var pendingFingerprint: String?
    var lastExport: Date?
    /// Unlike older versions' lastSuccess, this is confirmed by iCloud.
    var lastVerifiedUpload: Date?

    mutating func reconcile(_ result: CloudBackupFile.Upload, now: Date = .now) {
        switch result {
        case .pending: return
        case .missing, .replaced:
            pendingFingerprint = nil
            lastPrepared = nil
            lastFailure = now
            lastFailureMessage = "The prepared backup is no longer there. Casita will make a new copy."
        case .uploaded:
            lastSuccess = now
            lastVerifiedUpload = now
            pendingFingerprint = nil
            lastFailure = nil
            lastFailureMessage = nil
            pendingNote = nil
        case .failed(let message):
            lastFailure = now
            lastFailureMessage = message
            pendingNote = "The last backup hasn't uploaded. See Settings."
        }
    }

    static let key = "backup.status"
    static let scheduleKey = "backup.schedule"

    static var current: BackupStatus {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let status = try? JSONDecoder().decode(BackupStatus.self, from: data) else { return BackupStatus() }
            return status
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    /// Off until the person says yes: a space asks once, above Lock.
    static var schedule: BackupSchedule {
        get { UserDefaults.standard.string(forKey: scheduleKey).flatMap(BackupSchedule.init) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: scheduleKey) }
    }

    /// True until the person has chosen a schedule, here or in Settings.
    static var notAskedYet: Bool { UserDefaults.standard.string(forKey: scheduleKey) == nil }

    /// The one-line note for the next space that opens, if any.
    static func takeNote() -> String? {
        var status = current
        defer { status.pendingNote = nil; current = status }
        return status.pendingNote
    }
}

/// Automatic backups to the app's iCloud Drive container on a
/// `BGProcessingTask` that needs power and network, retaining a previous
/// copy until upload is confirmed. Needs `BGTaskSchedulerPermittedIdentifiers`
/// and `UIBackgroundModes: processing` in Info.plist and an iCloud Documents
/// entitlement, and `register()` before the app finishes launching.
@MainActor
final class BackupScheduler {
    static let shared = BackupScheduler()
    static let taskIdentifier = "com.hachly.casita.backup"
    nonisolated static let fileName = "Casita.\(BackupFile.fileExtension)"

    /// The open storage to back up. The app sets it after opening the file.
    var storage: ReservedStorage? {
        didSet { if oldValue !== storage { activeWork?.cancel() } }
    }
    private var running = false
    private var publishing = false
    private var checkingUpload = false
    private var activeWork: Task<Void, Error>?

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            let work = Task { @MainActor in
                let ok = await self.backUpToiCloud()
                self.schedule()
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Submits the next run per the chosen schedule. Call after launch and
    /// whenever the schedule changes.
    func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        guard StorageAccess.purchases.hasPlan, let interval = BackupStatus.schedule.interval else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = (BackupStatus.current.lastPrepared ?? BackupStatus.current.lastVerifiedUpload ?? .distantPast).addingTimeInterval(interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Leaving Casita while charging with a backup due: the iPhone is
    /// unlocked, so the storage file can be read, which a run in the middle
    /// of the night often can't. Uses the time iOS gives an app that just
    /// left; a run cut short keeps nothing.
    func backUpOnLeaving() {
        guard StorageAccess.purchases.hasPlan, storage != nil, let interval = BackupStatus.schedule.interval,
              (BackupStatus.current.lastPrepared ?? BackupStatus.current.lastVerifiedUpload ?? .distantPast).addingTimeInterval(interval) < .now else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        guard [.charging, .full].contains(UIDevice.current.batteryState) else { return }
        var id = UIBackgroundTaskIdentifier.invalid
        var work: Task<Void, Never>?
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
        id = UIApplication.shared.beginBackgroundTask { work?.cancel(); end() }
        work = Task {
            await backUpToiCloud()
            end()
        }
    }

    /// Writes a fresh backup and swaps it in for the previous one. Only on
    /// Wi-Fi and while the storage file can be read (complete protection
    /// shuts it while the iPhone is locked); otherwise it waits for the
    /// next run without calling that a problem.
    @discardableResult
    func backUpToiCloud() async -> Bool {
        guard !running, StorageAccess.purchases.hasPlan else { return false }
        running = true
        defer { running = false; activeWork = nil }
        await refreshUploadStatus()
        // Let an already-published copy finish; never replace it every time
        // iOS gives us another background opportunity.
        guard BackupStatus.current.pendingFingerprint == nil else { return true }
        guard UIApplication.shared.isProtectedDataAvailable, await Self.onWiFi() else { return false }
        var staging: URL?
        do {
            guard let storage else { throw BackupError.corrupt }
            let container = await Task.detached { FileManager.default.url(forUbiquityContainerIdentifier: nil) }.value
            guard let documents = container?.appendingPathComponent("Documents", isDirectory: true) else {
                throw BackupError.iCloudUnavailable
            }
            let destination = documents.appendingPathComponent(Self.fileName)
            // Written outside iCloud Drive, so a run that dies leaves no
            // half-uploaded file there; launch sweeps what is left here.
            let file = try MediaTemp.newFile(named: Self.fileName)
            staging = file
            let work = Task {
                try await storage.writeBackup(to: file)
                try Task.checkCancellation()
                guard self.storage === storage, StorageAccess.purchases.hasPlan else { throw CancellationError() }
                let fingerprint = try CloudBackupFile.fingerprint(file)
                self.publishing = true
                defer { self.publishing = false }
                var status = BackupStatus.current
                status.pendingFingerprint = fingerprint
                status.lastPrepared = .now
                BackupStatus.current = status
                let publication = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    try CloudBackupFile.publish(file, to: destination)
                }
                try await withTaskCancellationHandler {
                    try await publication.value
                } onCancel: { publication.cancel() }
            }
            activeWork = work
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            MediaTemp.remove(file)
            var status = BackupStatus.current
            status.lastFailure = nil
            status.lastFailureMessage = nil
            status.pendingNote = nil
            BackupStatus.current = status
            await refreshUploadStatus()
            return true
        } catch {
            if let staging { MediaTemp.remove(staging) }
            var interrupted = BackupStatus.current
            interrupted.pendingFingerprint = nil
            interrupted.lastPrepared = nil
            BackupStatus.current = interrupted
            if error is CancellationError { return false }
            // The iPhone locked partway through: not a problem, just later.
            guard UIApplication.shared.isProtectedDataAvailable else { return false }
            var status = BackupStatus.current
            status.lastFailure = .now
            status.lastFailureMessage = Self.message(for: error)
            status.pendingNote = "The last backup didn't finish. See Settings."
            BackupStatus.current = status
            return false
        }
    }

    /// A local file handoff is not an uploaded backup. Check metadata again
    /// at launch, in Settings, and before scheduling another copy.
    func refreshUploadStatus() async {
        guard !publishing, !checkingUpload else { return }
        guard let fingerprint = BackupStatus.current.pendingFingerprint else { return }
        checkingUpload = true
        defer { checkingUpload = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
                    throw BackupError.iCloudUnavailable
                }
                let destination = container.appendingPathComponent("Documents").appendingPathComponent(Self.fileName)
                return try CloudBackupFile.uploadState(at: destination, fingerprint: fingerprint, removeFallbackIfUploaded: true)
            }.value
            var status = BackupStatus.current
            guard status.pendingFingerprint == fingerprint else { return }
            status.reconcile(result)
            BackupStatus.current = status
        } catch {
            var status = BackupStatus.current
            guard status.pendingFingerprint == fingerprint else { return }
            status.lastFailure = .now
            status.lastFailureMessage = backupErrorMessage(error)
            BackupStatus.current = status
        }
    }

    /// Whether the iPhone is on a connection that isn't metered (Wi-Fi).
    private static func onWiFi() async -> Bool {
        await withCheckedContinuation { done in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                done.resume(returning: path.status == .satisfied && !path.isExpensive)
            }
            monitor.start(queue: DispatchQueue(label: "casita.backup.path"))
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case BackupError.iCloudUnavailable: "iCloud Drive isn't available on this iPhone."
        default: "Backup couldn't be written: \(error.localizedDescription)"
        }
    }
}
