import CryptoKit
import Foundation

enum BackupError: Error, Equatable {
    case notBackupFile
    /// The words match no space in the file.
    case wrongRecoveryKey
    case corrupt
    /// No space lets these words reset its code; the file can't tell whether
    /// the words are wrong or the switch is off.
    case cannotReset
    case iCloudUnavailable
}

/// Everything that needs recovery words: sealing portable slots and backups
/// to per-slot public keys, and opening them with the private keys the words
/// give.
///
/// Each space is sealed to the words it was last given, so different spaces
/// can be on different words. A space only ever touches the portable slots it
/// was given (`SpaceHeader.givenSlots`), which no space outside its subtree
/// uses, so nothing here can fail or behave differently because of spaces
/// elsewhere.
extension ReservedStorage {
    static let hpkeSuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    // MARK: HPKE

    /// enc (32) ‖ ciphertext ‖ tag (16).
    static func hpkeSeal(_ plain: Data, to publicKey: Curve25519.KeyAgreement.PublicKey, info: Data) throws -> Data {
        var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: hpkeSuite, info: info)
        let ciphertext = try sender.seal(plain)
        return sender.encapsulatedKey + ciphertext
    }

    static func hpkeOpen(_ sealed: Data, with privateKey: Curve25519.KeyAgreement.PrivateKey, info: Data) throws -> Data {
        guard sealed.count > 48 else { throw BackupError.corrupt }
        let enc = sealed.prefix(32)
        var recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: hpkeSuite, info: info, encapsulatedKey: enc)
        do { return try recipient.open(sealed.dropFirst(32)) } catch { throw BackupError.wrongRecoveryKey }
    }

    /// The code wrap and reset part in `slot`'s portable slot, when `words`
    /// is what it is sealed to.
    private func openPortableSlot(_ slot: Int, with words: RecoveryKey) throws -> (codeWrap: Data, reset: Data)? {
        let sealed = try read(at: Self.portableOffset(slot), count: Self.portableSlotSize)
        guard let plain = try? Self.hpkeOpen(sealed.dropFirst(32), with: words.privateKey(forSlot: slot), info: Self.portableInfo(slot)),
              plain.count == Self.portablePlainSize
        else { return nil }
        return (plain.prefix(Self.slotSize), plain.suffix(Self.slotPlainSize))
    }

    /// Header key and first header chunk from a device slot, code wrap or
    /// reset part.
    private static func splitSlotPlain(_ plain: Data) -> (headerKey: SymmetricKey, headerChunk: UInt32)? {
        guard plain.count == slotPlainSize else { return nil }
        let chunk = plain.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return (SymmetricKey(data: plain.prefix(32)), UInt32(littleEndian: chunk))
    }

    // MARK: Recovery key

    /// Seals `ref` and every space under it to new words, and nothing else.
    /// Spaces elsewhere keep the words they were sealed to, so a new key from
    /// any space is safe. A space's children start on its words when they are
    /// created, and move with it here.
    func setRecoveryKey(_ key: RecoveryKey, from ref: SpaceRef) throws {
        let keys = (0..<Self.slotCount).map { key.publicKey(forSlot: $0).rawRepresentation }
        var live: [Int: SpaceState] = [:]
        for (slot, var state) in try subtree(of: ref) {
            state.header.recoveryKeys = Dictionary(uniqueKeysWithValues: state.header.givenSlots.map { ($0, keys[$0]) })
            try store(state, slot: slot)
            live[slot] = state
        }
        try rewritePortableSlots(given: try self.state(ref).header.givenSlots, live: live, freshKeys: true)
    }

    /// `ref` and every space under it that still opens: `ref` as it is in
    /// memory, the others as their parents' keys load them from disk. The two
    /// always match, since every change is saved at once.
    private func subtree(of ref: SpaceRef) throws -> [(slot: Int, state: SpaceState)] {
        var result: [(slot: Int, state: SpaceState)] = []
        func visit(_ slot: Int, _ state: SpaceState) {
            result.append((slot, state))
            for child in state.header.children {
                let key = SymmetricKey(data: child.headerKey)
                guard let header = try? loadHeader(key: key, firstChunk: child.headerChunk) else { continue }
                visit(child.slot, SpaceState(header: header, headerKey: key))
            }
        }
        visit(ref.slot, try state(ref))
        return result
    }

    /// Saves a space reached through its parent without leaving it open.
    private func store(_ state: SpaceState, slot: Int) throws {
        let wasOpen = spaces[slot] != nil
        try save(state, slot: slot)
        if !wasOpen { spaces[slot] = nil }
    }

    /// Rewrites every portable slot in `given`: real seals for the spaces in
    /// `live`, random seals for the rest, so a look at the file before and
    /// after can't tell which of them are in use. With `freshKeys` the unused
    /// ones also get new throwaway keys, as the used ones get new words.
    /// Always does `slotCount` seals, however many slots `given` holds.
    private func rewritePortableSlots(given: Set<Int>, live: [Int: SpaceState], freshKeys: Bool) throws {
        for slot in 0..<Self.slotCount {
            if given.contains(slot) {
                try writePortableSlot(slot, for: live[slot], freshKey: freshKeys)
            } else {
                _ = try Self.portableSlot(slot, publicKey: Self.throwawayPublicKey(), plain: Self.randomBytes(Self.portablePlainSize))
            }
        }
    }

    // MARK: Codes

    /// Changes a space's code: device slot, code wrap and portable slot.
    func setCode(_ code: String, for ref: SpaceRef) throws {
        var state = try state(ref)
        let key = try stretcher.stretch(code: code, salt: salt)
        if let hit = try slotOpening(with: key), hit.slot != ref.slot { throw StorageError.codeInUse }
        let plain = Self.slotPlain(state.headerKey, state.header.headerChunks[0])
        state.header.codeWrap = try AES.GCM.seal(plain, using: codeWrapKey(code)).combined!
        try save(state, slot: ref.slot)
        try writeDeviceSlot(ref.slot, headerKey: state.headerKey, headerChunk: state.header.headerChunks[0], under: key)
        try writePortableSlot(ref.slot, for: state)
    }

    /// After a restore: finds the space `code` belongs to through its
    /// portable slot and wraps it under this phone's stretched code. Every
    /// portable slot is tried, no early exit. nil when no space sealed to
    /// these words has this code; spaces sealed to other words never open.
    func adopt(code: String, recoveryKey: RecoveryKey) throws -> SpaceRef? {
        let wrapKey = codeWrapKey(code)
        var found: (slot: Int, headerKey: SymmetricKey, headerChunk: UInt32)?
        var matches = 0
        for slot in 0..<Self.slotCount {
            guard let opened = try openPortableSlot(slot, with: recoveryKey),
                  let box = try? AES.GCM.SealedBox(combined: opened.codeWrap),
                  let plain = try? AES.GCM.open(box, using: wrapKey),
                  let (headerKey, headerChunk) = Self.splitSlotPlain(plain)
            else { continue }
            matches += 1
            if found == nil { found = (slot, headerKey, headerChunk) }
        }
        guard matches <= 1 else { throw StorageError.codeInUse }
        guard let found else { return nil }
        let header = try loadHeader(key: found.headerKey, firstChunk: found.headerChunk)
        let key = try stretcher.stretch(code: code, salt: salt)
        if let hit = try slotOpening(with: key), hit.slot != found.slot { throw StorageError.codeInUse }
        try writeDeviceSlot(found.slot, headerKey: found.headerKey, headerChunk: found.headerChunk, under: key)
        spaces[found.slot] = SpaceState(header: header, headerKey: found.headerKey)
        return SpaceRef(slot: found.slot)
    }

    // MARK: Reset a code with the words (opt-in, per space)

    /// On: `ref`'s portable slot also seals its header key straight to its
    /// words, so the words alone can give it a new code. Off: random bytes of
    /// the same size sit there instead. Rewrites every portable slot `ref`
    /// was given, keeping their keys, so the file doesn't show which changed.
    func setResetWithRecoveryKey(_ on: Bool, for ref: SpaceRef) throws {
        var state = try state(ref)
        state.header.resetWithRecoveryKey = on
        try save(state, slot: ref.slot)
        let live = Dictionary(try subtree(of: ref).map { ($0.slot, $0.state) }, uniquingKeysWith: { first, _ in first })
        try rewritePortableSlots(given: state.header.givenSlots, live: live, freshKeys: false)
    }

    /// Opens, with the words alone, a space whose reset switch is on and that
    /// is sealed to these words, and gives it `newCode`. Every portable slot
    /// is tried. When several match, the one the others sit under is reset
    /// (it reaches them anyway); matches with nothing above them are taken in
    /// slot order.
    func resetCode(to newCode: String, with recoveryKey: RecoveryKey) throws -> SpaceRef {
        var matches: [Int: SpaceState] = [:]
        for slot in 0..<Self.slotCount {
            guard let opened = try openPortableSlot(slot, with: recoveryKey),
                  let (headerKey, headerChunk) = Self.splitSlotPlain(opened.reset),
                  let header = try? loadHeader(key: headerKey, firstChunk: headerChunk),
                  header.resetWithRecoveryKey, header.ownSlot == slot
            else { continue }
            matches[slot] = SpaceState(header: header, headerKey: headerKey)
        }
        let under = matches.values.reduce(into: Set<Int>()) { $0.formUnion($1.header.givenSlots.subtracting([$1.header.ownSlot])) }
        guard let slot = matches.keys.filter({ !under.contains($0) }).min(), let state = matches[slot] else {
            throw BackupError.cannotReset
        }
        let ref = SpaceRef(slot: slot)
        spaces[slot] = state
        try setCode(newCode, for: ref)
        return ref
    }

    // MARK: Backup and restore

    /// The whole file sealed to the key at the front of every portable slot,
    /// so whichever words a space is sealed to open it. Needs no open space:
    /// the keys are in plain. Runs on the actor so nothing writes while it
    /// reads.
    func writeBackup(to output: URL) throws {
        var keys: [Curve25519.KeyAgreement.PublicKey] = []
        for slot in 0..<Self.slotCount {
            let raw = try read(at: Self.portableOffset(slot), count: 32)
            keys.append((try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)) ?? Self.throwawayPublicKey())
        }
        try BackupFile.seal(storageAt: url, bytes: byteSize, to: keys, output: output)
    }

    /// Rebuilds reserved storage from a backup on this phone. Throws
    /// `wrongRecoveryKey` when the words match no space in it. Device slots
    /// come back empty under a fresh salt; `adopt(code:recoveryKey:)` fills
    /// them one code at a time, for the spaces sealed to these words. Spaces
    /// sealed to other words stay in the file untouched and can be adopted
    /// later with theirs.
    static func restore(backup: URL, recoveryKey: RecoveryKey, to url: URL, stretcher: any CodeStretcher) throws -> ReservedStorage {
        try BackupFile.open(backup, with: recoveryKey, output: url)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 8)
        try handle.write(contentsOf: randomBytes(32))
        for slot in 0..<slotCount {
            try handle.seek(toOffset: slotOffset(slot))
            try handle.write(contentsOf: randomBytes(slotSize))
        }
        try handle.close()
        return try open(at: url, stretcher: stretcher)
    }
}
