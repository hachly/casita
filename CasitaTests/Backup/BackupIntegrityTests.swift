import Foundation
import Testing
@testable import Casita

/// Corrupted backups must never leave a usable or partial restored store.
@Suite struct BackupIntegrityTests {
    @Test(arguments: ["short-header", "truncated-segment", "missing-segments", "changed-byte", "extra-byte", "swapped-segments"])
    func damagedBackupsFailWithoutLeavingRestoredStorage(_ damage: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original")
        let backup = directory.appendingPathComponent("backup")
        let output = directory.appendingPathComponent("restored")
        let key = RecoveryKey()
        let bytes = Int64(ReservedStorage.chunksOffset + 40 * ReservedStorage.chunkSealed)
        let storage = try ReservedStorage.create(at: original, bytes: bytes, stretcher: PBKDF2Stretcher(iterations: 1000))
        await storage.setCodeWrapIterations(1000)
        let top = try await storage.createTopSpace(code: "audit-code")
        try await storage.writeFile(named: "example", data: Data("restore me".utf8), in: top)
        try await storage.setRecoveryKey(key, from: top)
        try await storage.writeBackup(to: backup)
        var data = try Data(contentsOf: backup)
        switch damage {
        case "short-header": data = Data(data.prefix(BackupFile.headerSize - 1))
        case "truncated-segment": data.removeLast(7)
        case "missing-segments": data = Data(data.prefix(BackupFile.headerSize + BackupFile.segmentSealed))
        case "changed-byte": data[BackupFile.headerSize + 100] ^= 1
        case "extra-byte": data.append(1)
        case "swapped-segments":
            let start = BackupFile.headerSize, size = BackupFile.segmentSealed
            let first = Data(data[start..<start + size])
            let second = Data(data[start + size..<start + 2 * size])
            data.replaceSubrange(start..<start + size, with: second)
            data.replaceSubrange(start + size..<start + 2 * size, with: first)
        default: fatalError("Unknown probe")
        }
        try data.write(to: backup)
        #expect(throws: damage == "short-header" ? BackupError.notBackupFile : BackupError.corrupt) {
            try ReservedStorage.restore(backup: backup, recoveryKey: key, to: output, stretcher: PBKDF2Stretcher(iterations: 1000))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
