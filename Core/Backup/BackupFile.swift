import CryptoKit
import Foundation

/// A backup is the whole reserved storage as one file, under a content key
/// made fresh for every backup:
///
/// magic ‖ `slotCount` key seals ‖ 1 MiB segments
///
/// Key seal `i` is an HPKE seal of the content key to the recovery public key
/// at the front of portable slot `i`: real words for slots in use, a
/// throwaway key for the rest, so all of them look alike. Whichever words a
/// space is sealed to open its key seal, and with it the whole file. Each
/// segment is AES-GCM under the content key with the segment index as nonce
/// and additional data.
///
/// Size depends only on the storage size. Every byte after the magic differs
/// between two backups, even of unchanged storage, so backups can't be
/// compared with each other or with the phone.
enum BackupFile {
    static let magic = Data("CASITAB2".utf8)
    static let segmentPlain = 1 << 20
    static let segmentSealed = segmentPlain + 28
    /// HPKE: enc 32 + content key 32 + tag 16
    static let keySealSize = 80
    static let headerSize = magic.count + ReservedStorage.slotCount * keySealSize
    static let fileExtension = "casitabackup"

    static func size(forStorageBytes bytes: Int64) -> Int64 {
        let segments = (bytes + Int64(segmentPlain) - 1) / Int64(segmentPlain)
        return Int64(headerSize) + bytes + segments * 28
    }

    /// `publicKeys`: the key at the front of each portable slot, in slot order.
    static func seal(storageAt input: URL, bytes: Int64, to publicKeys: [Curve25519.KeyAgreement.PublicKey], output: URL) throws {
        precondition(publicKeys.count == ReservedStorage.slotCount)
        let key = SymmetricKey(size: .bits256)
        var head = magic
        for (slot, publicKey) in publicKeys.enumerated() {
            head.append(try ReservedStorage.hpkeSeal(key.withUnsafeBytes { Data($0) }, to: publicKey, info: info(slot)))
        }
        precondition(head.count == headerSize)
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        let writer = try ReservedStorage.makeFile(at: output)
        defer { try? writer.close() }
        try writer.write(contentsOf: head)
        var index: UInt64 = 0
        var remaining = bytes
        while remaining > 0 {
            try Task.checkCancellation()
            let n = Int(min(Int64(segmentPlain), remaining))
            guard let plain = try reader.read(upToCount: n), plain.count == n else { throw BackupError.corrupt }
            try writer.write(contentsOf: try AES.GCM.seal(plain, using: key, nonce: nonce(index), authenticating: aad(index)).combined!)
            index += 1
            remaining -= Int64(n)
        }
    }

    /// Writes the reserved storage inside `input` to `output`. Every key seal
    /// is tried with its slot's key from `words`, no early exit. Throws
    /// `wrongRecoveryKey` when none opens, meaning no space in the backup is
    /// sealed to these words, and `corrupt` when a segment fails or the
    /// storage comes out shorter than its header says.
    static func open(_ input: URL, with words: RecoveryKey, output: URL) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        guard let head = try reader.read(upToCount: headerSize), head.count == headerSize,
              head.prefix(magic.count) == magic
        else { throw BackupError.notBackupFile }
        var found: SymmetricKey?
        for slot in 0..<ReservedStorage.slotCount {
            let start = head.startIndex + magic.count + slot * keySealSize
            let seal = head[start..<start + keySealSize]
            guard let plain = try? ReservedStorage.hpkeOpen(seal, with: words.privateKey(forSlot: slot), info: info(slot)),
                  plain.count == 32
            else { continue }
            if found == nil { found = SymmetricKey(data: plain) }
        }
        guard let key = found else { throw BackupError.wrongRecoveryKey }

        let writer = try ReservedStorage.makeFile(at: output)
        var finished = false
        defer {
            try? writer.close()
            if !finished { try? FileManager.default.removeItem(at: output) }
        }
        var index: UInt64 = 0
        var written: Int64 = 0
        var declared: Int64?
        while let sealed = try reader.read(upToCount: segmentSealed), !sealed.isEmpty {
            try Task.checkCancellation()
            guard let box = try? AES.GCM.SealedBox(combined: sealed),
                  let plain = try? AES.GCM.open(box, using: key, authenticating: aad(index))
            else { throw BackupError.corrupt }
            if declared == nil, plain.count >= 48 {
                declared = plain[plain.startIndex + 40..<plain.startIndex + 48].withUnsafeBytes { Int64(littleEndian: $0.loadUnaligned(as: Int64.self)) }
            }
            try writer.write(contentsOf: plain)
            written += Int64(plain.count)
            index += 1
        }
        guard let declared, written == declared else { throw BackupError.corrupt }
        finished = true
    }

    private static func info(_ slot: Int) -> Data { Data("casita.backup.\(slot)".utf8) }

    private static func nonce(_ index: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: aad(index) + Data(count: 4))
    }

    private static func aad(_ index: UInt64) -> Data {
        withUnsafeBytes(of: index.littleEndian) { Data($0) }
    }
}
