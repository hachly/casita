import CryptoKit
import Foundation

/// File-provider operations run off the main actor. The previous complete
/// file remains available until the new version is confirmed uploaded.
enum CloudBackupFile {
    static let previousName = "Casita Previous.\(BackupFile.fileExtension)"
    enum Upload: Equatable, Sendable { case pending, uploaded, missing, replaced, failed(String) }

    static func fingerprint(_ url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        guard let header = try reader.read(upToCount: BackupFile.headerSize), header.count == BackupFile.headerSize else {
            throw BackupError.corrupt
        }
        return SHA256.hash(data: header).map { String(format: "%02x", $0) }.joined()
    }

    static func publish(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: (any Error)?
        let previousURL = directory.appendingPathComponent(previousName)
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing,
            writingItemAt: previousURL, options: .forReplacing, error: &coordinationError) { destination, previous in
            do {
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: destination.path) {
                    let hasPrevious = FileManager.default.fileExists(atPath: previous.path)
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: source,
                        backupItemName: hasPrevious ? nil : previousName, options: .withoutDeletingBackupItem)
                } else {
                    try FileManager.default.moveItem(at: source, to: destination)
                }
                // The backup is sealed to the recovery sentence, so complete
                // protection adds nothing; it would let iCloud upload it only
                // while the iPhone is unlocked, and a pending upload holds
                // back every later backup.
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    static func uploadState(at url: URL, fingerprint expected: String, removeFallbackIfUploaded: Bool = false) throws -> Upload {
        var coordinationError: NSError?
        var result: Upload = .pending
        func inspect(_ readable: URL, fallback: URL?) {
            do {
                guard try fingerprint(readable) == expected else { result = .replaced; return }
                // Metadata and bytes must describe the same coordinated
                // version, including when another device has replaced it.
                var current = readable
                current.removeAllCachedResourceValues()
                let values = try current.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
                if let error = values.ubiquitousItemUploadingError { result = .failed(error.localizedDescription) }
                else { result = values.ubiquitousItemIsUploaded == true ? .uploaded : .pending }
                if result == .uploaded, let fallback, FileManager.default.fileExists(atPath: fallback.path) {
                    try FileManager.default.removeItem(at: fallback)
                }
            } catch {
                if isMissing(error) { result = .missing }
                else if (error as? BackupError) == .corrupt { result = .replaced }
                else { result = .failed(backupErrorMessage(error)) }
            }
        }
        let fallback = url.deletingLastPathComponent().appendingPathComponent(previousName)
        if removeFallbackIfUploaded, FileManager.default.fileExists(atPath: fallback.path) {
            // Verify the current generation and remove its fallback under
            // the same coordination, so a replacement cannot slip between.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], writingItemAt: fallback,
                options: .forDeleting, error: &coordinationError) { readable, previous in inspect(readable, fallback: previous) }
        } else {
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { inspect($0, fallback: nil) }
        }
        if let coordinationError {
            if isMissing(coordinationError) { return .missing }
            throw coordinationError
        }
        return result
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    static func removePrevious(nextTo destination: URL) throws {
        let previous = destination.deletingLastPathComponent().appendingPathComponent(previousName)
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        var coordinationError: NSError?
        var deletionError: (any Error)?
        NSFileCoordinator().coordinate(writingItemAt: previous, options: .forDeleting, error: &coordinationError) { url in
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } catch { deletionError = error }
        }
        if let coordinationError { throw coordinationError }
        if let deletionError { throw deletionError }
    }
}
