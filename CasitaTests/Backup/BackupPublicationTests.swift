import Foundation
import Testing
@testable import Casita

@Suite struct BackupPublicationTests {
    @Test func publicationPreservesFallbackAcrossInterruptedReplacements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Casita.casitabackup")
        let previous = directory.appendingPathComponent(CloudBackupFile.previousName)
        func publish(_ byte: UInt8) throws {
            let staging = directory.appendingPathComponent("staging-\(byte)")
            try Data(repeating: byte, count: BackupFile.headerSize + 100).write(to: staging)
            try CloudBackupFile.publish(staging, to: destination)
        }
        try publish(1)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        try CloudBackupFile.removePrevious(nextTo: destination) // first backup has no fallback
        try publish(2)
        #expect(try Data(contentsOf: destination).first == 2)
        #expect(try Data(contentsOf: previous).first == 1)
        // A prior attempt was interrupted before acknowledgement: keep its
        // known-good fallback while a new complete file is swapped in.
        try publish(3)
        #expect(try Data(contentsOf: destination).first == 3)
        #expect(try Data(contentsOf: previous).first == 1)
        try CloudBackupFile.removePrevious(nextTo: destination)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(try Data(contentsOf: destination).first == 3)
        // iCloud must be able to upload it while the iPhone is locked. (The
        // simulator may report no class at all; a phone reports this one.)
        let protection = try FileManager.default.attributesOfItem(atPath: destination.path)[.protectionKey] as? FileProtectionType
        #expect(protection == nil || protection == .completeUntilFirstUserAuthentication)
    }

    @Test func pendingJournalCanRecoverBeforePublicationOrAfterAnotherDeviceWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("backup")
        #expect(try CloudBackupFile.uploadState(at: destination, fingerprint: "unpublished") == .missing)
        var status = BackupStatus(lastPrepared: .now, pendingFingerprint: "unpublished")
        status.reconcile(.missing)
        #expect(status.pendingFingerprint == nil)
        #expect(status.lastPrepared == nil)
        try Data(repeating: 4, count: BackupFile.headerSize).write(to: destination)
        #expect(try CloudBackupFile.uploadState(at: destination, fingerprint: "another-version") == .replaced)
        status.pendingFingerprint = "another-version"
        status.reconcile(.replaced)
        #expect(status.pendingFingerprint == nil)
        #expect(status.lastVerifiedUpload == nil)
        try Data([1, 2, 3]).write(to: destination)
        #expect(try CloudBackupFile.uploadState(at: destination, fingerprint: "damaged") == .replaced)
    }

    @Test func onlyVerifiedUploadCountsAsCloudSuccess() throws {
        var status = BackupStatus(lastPrepared: .now, pendingFingerprint: "new")
        status.reconcile(.pending)
        #expect(status.lastVerifiedUpload == nil)
        status.reconcile(.failed("iCloud is full"))
        #expect(status.pendingFingerprint == "new")
        #expect(status.lastVerifiedUpload == nil)
        let confirmed = Date(timeIntervalSince1970: 1_800_000_000)
        status.reconcile(.uploaded, now: confirmed)
        #expect(status.lastVerifiedUpload == confirmed)
        #expect(status.pendingFingerprint == nil)
        #expect(status.lastFailure == nil)
        // Historical lastSuccess meant only a local file handoff.
        let old = try JSONDecoder().decode(BackupStatus.self, from: Data("{\"lastSuccess\":123}".utf8))
        #expect(old.lastVerifiedUpload == nil)
    }
}
