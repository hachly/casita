import CryptoKit
import Foundation
import Security

/// One fixed-size file holding every space.
///
/// Layout: a 4 KiB plain header (magic, salt, size, an unused key field,
/// portable salt, random padding), then `slotCount` device slots of
/// `slotSize` bytes, then `slotCount` portable slots of `portableSlotSize`
/// bytes, then fixed-size sealed chunks to the end of the file. Unused slots
/// and chunks hold random bytes or seals to throwaway keys, which look the
/// same as real ones, so nothing in the file says how many spaces exist.
///
/// A code is stretched once and tried against every device slot. A slot that
/// opens gives the header key and first header chunk of a space. Chunks the
/// file index points at are sealed under that space's master key.
///
/// The portable slot of a space starts with the recovery public key that
/// slot is sealed to (one per slot, derived from the words), then holds the
/// same header key and chunk wrapped under PBKDF2 of the code (no Secure
/// Enclave), plus the space's reset part, HPKE-sealed to that key. Each space
/// can be sealed to different words. Restoring on another phone needs the
/// words and each space's code; see `ReservedStorage+Recovery.swift`.
actor ReservedStorage {
    static let fileHeaderSize = 4096
    /// magic 8 + salt 32 + size 8 + unused key field 32 + portable salt 32
    static let fileHeaderFixed = 112
    static let slotCount = 32
    /// nonce 12 + (header key 32 + header chunk 4) + tag 16
    static let slotSize = 64
    /// Header key 32 + header chunk 4: what a device slot, a code wrap and a
    /// reset part each hold.
    static let slotPlainSize = 36
    /// What a portable slot seals: code wrap (`slotSize`) + reset part
    /// (`slotPlainSize`, real when the space's reset switch is on, random
    /// when off).
    static let portablePlainSize = slotSize + slotPlainSize
    /// Recovery public key 32 + HPKE (enc 32 + `portablePlainSize` + tag 16)
    static let portableSlotSize = 32 + 32 + portablePlainSize + 16
    static let chunkPlain = 65_536
    static let chunkSealed = chunkPlain + 28
    static let portableOffset = fileHeaderSize + slotCount * slotSize
    static let chunksOffset = portableOffset + slotCount * portableSlotSize
    static let minimumBytes = Int64(chunksOffset + 8 * chunkSealed)
    private static let magic = Data("CASITA03".utf8)
    static let endOfChain = UInt32.max
    /// Every space can hold this many spaces directly under it, the top
    /// included, so the limit says nothing about where a space sits.
    static let maxChildren = 4

    nonisolated let url: URL
    nonisolated let access: StorageAccess
    let handle: FileHandle
    let stretcher: any CodeStretcher
    let salt: Data
    /// Salt for the code wrap inside portable slots. Never rotates, so it
    /// survives a restore.
    let portableSalt: Data
    private(set) var byteSize: Int64
    /// Every unlock attempt, right or wrong, takes at least this long.
    private(set) var minimumUnlockDuration: Duration = .seconds(1)
    /// PBKDF2 rounds for the code wrap in portable slots. Tests lower it.
    private(set) var codeWrapIterations: UInt32 = 600_000

    func setMinimumUnlockDuration(_ duration: Duration) {
        minimumUnlockDuration = duration
    }

    func setCodeWrapIterations(_ iterations: UInt32) {
        codeWrapIterations = iterations
    }
    var spaces: [Int: SpaceState] = [:]

    struct SpaceState {
        var header: SpaceHeader
        var headerKey: SymmetricKey
        var masterKey: SymmetricKey { SymmetricKey(data: header.masterKey) }
    }

    var chunkCount: Int { Int((byteSize - Int64(Self.chunksOffset)) / Int64(Self.chunkSealed)) }

    // MARK: Create and open

    static func create(at url: URL, size: StorageSize, stretcher: any CodeStretcher) throws -> ReservedStorage {
        try create(at: url, bytes: size.rawValue, stretcher: stretcher)
    }

    /// Until a space gets words from `setRecoveryKey`, its portable slot (and
    /// so its share of every backup) is sealed to a throwaway key nobody holds.
    static func create(at url: URL, bytes: Int64, stretcher: any CodeStretcher) throws -> ReservedStorage {
        precondition(bytes >= minimumBytes)
        let handle = try makeFile(at: url)
        let salt = randomBytes(32)
        let portableSalt = randomBytes(32)
        let unusedKey = throwawayPublicKey()
        try writeFileHeader(handle, salt: salt, bytes: bytes, publicKey: unusedKey, portableSalt: portableSalt)
        try fillRandom(handle, from: Int64(fileHeaderFixed), to: bytes)
        try writeThrowawayPortableSlots(handle)
        return ReservedStorage(
            url: url, handle: handle, stretcher: stretcher, salt: salt,
            portableSalt: portableSalt, publicKey: unusedKey, byteSize: bytes
        )
    }

    /// Every portable slot sealed to a key nobody keeps.
    private static func writeThrowawayPortableSlots(_ handle: FileHandle) throws {
        for slot in 0..<slotCount {
            try handle.seek(toOffset: portableOffset(slot))
            try handle.write(contentsOf: try portableSlot(slot, publicKey: throwawayPublicKey(), plain: randomBytes(portablePlainSize)))
        }
    }

    static func open(at url: URL, stretcher: any CodeStretcher, access: StorageAccess = .unrestricted) throws -> ReservedStorage {
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: fileHeaderFixed), head.count == fileHeaderFixed, head.prefix(8) == magic else {
            throw StorageError.notCasitaFile
        }
        let salt = head[8..<40]
        let bytes = head[40..<48].withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: head[48..<80])
        let portableSalt = head[80..<112]
        let actual = try handle.seekToEnd()
        // A grow that died after extending the file but before the header
        // recorded it leaves extra bytes nobody owns; drop them.
        if Int64(actual) > bytes { try handle.truncate(atOffset: UInt64(bytes)) }
        guard Int64(actual) >= bytes else { throw StorageError.wrongFileSize }
        return ReservedStorage(
            url: url, handle: handle, stretcher: stretcher, salt: Data(salt),
            portableSalt: Data(portableSalt), publicKey: publicKey, byteSize: bytes, access: access
        )
    }

    /// A new file with complete protection, kept out of iCloud device backup.
    static func makeFile(at url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(
            atPath: url.path, contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else { throw StorageError.notCasitaFile }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try url.setResourceValues(values)
        return try FileHandle(forUpdating: url)
    }

    /// `publicKey` is the header field at 48..<80. It held the file's one
    /// recovery key; now every portable slot carries its own, so the field is
    /// a throwaway key written at create and never used. `open(at:)` still
    /// reads it.
    private init(
        url: URL, handle: FileHandle, stretcher: any CodeStretcher, salt: Data,
        portableSalt: Data, publicKey: Curve25519.KeyAgreement.PublicKey, byteSize: Int64, access: StorageAccess = .unrestricted
    ) {
        self.url = url
        self.access = access
        self.handle = handle
        self.stretcher = stretcher
        self.salt = salt
        self.portableSalt = portableSalt
        self.byteSize = byteSize
    }

    // MARK: Spaces

    /// Makes the first space, which owns every chunk and every slot. A third
    /// of the chunks go to its unlisted reserve: once it gives half its free
    /// room to the everyday space, both see the same free room, and neither
    /// can tell from the numbers whether a space sits above it.
    func createTopSpace(code: String) throws -> SpaceRef {
        let key = try stretcher.stretch(code: code, salt: salt)
        guard try slotOpening(with: key) == nil else { throw StorageError.codeInUse }
        let slots = Array(0..<Self.slotCount).shuffled()
        let listed = UInt32(chunkCount - chunkCount / 3)
        let header = SpaceHeader(
            masterKey: Self.randomBytes(32), room: Array(0..<listed),
            slots: slots, headerChunks: [], files: [], children: [],
            codeWrap: Data(), resetWithRecoveryKey: false, recoveryKeys: [:],
            reserve: Array(listed..<UInt32(chunkCount))
        )
        return try register(header: header, wrappedBy: key, code: code)
    }

    /// Tries `code` against every slot. Returns nil for a wrong code. Always
    /// takes at least `minimumUnlockDuration`.
    func unlock(code: String) async throws -> SpaceRef? {
        let clock = ContinuousClock()
        let start = clock.now
        defer { try? touchFileHeader() }

        let key = try stretcher.stretch(code: code, salt: salt)
        var result: SpaceRef?
        if let (slot, headerKey, headerChunk) = try slotOpening(with: key) {
            let header = try loadHeader(key: headerKey, firstChunk: headerChunk)
            spaces[slot] = SpaceState(header: header, headerKey: headerKey)
            result = SpaceRef(slot: slot)
        }
        let remaining = minimumUnlockDuration - start.duration(to: clock.now)
        if remaining > .zero { try await Task.sleep(for: remaining) }
        return result
    }

    func credential(for ref: SpaceRef) throws -> SpaceCredential {
        let state = try state(ref)
        return SpaceCredential(
            slot: ref.slot, headerKey: state.headerKey.withUnsafeBytes { Data($0) },
            headerChunk: state.header.headerChunks[0]
        )
    }

    func open(_ credential: SpaceCredential) throws -> SpaceRef {
        let key = SymmetricKey(data: credential.headerKey)
        let header = try loadHeader(key: key, firstChunk: credential.headerChunk)
        spaces[credential.slot] = SpaceState(header: header, headerKey: key)
        return SpaceRef(slot: credential.slot)
    }

    func lock(_ ref: SpaceRef) {
        spaces[ref.slot] = nil
    }

    func lockAll() {
        spaces.removeAll()
    }

    /// Makes a space under `parent` with `chunks` of the parent's free room.
    func createChild(of parent: SpaceRef, name: String, code: String, chunks: Int) throws -> SpaceRef {
        guard access.hasPlan else { throw PlanLimit.spaces }
        var state = try state(parent)
        let key = try stretcher.stretch(code: code, salt: salt)
        guard try slotOpening(with: key) == nil else { throw StorageError.codeInUse }
        let free = state.header.freeChunks
        guard chunks >= 1, free.count >= chunks else { throw StorageError.noRoom }
        guard state.header.children.count < Self.maxChildren else { throw StorageError.noSlots }
        var spare = state.header.spareSlots.shuffled()
        guard !spare.isEmpty else { throw StorageError.noSlots }
        let ownSlot = spare.removeFirst()
        let grantedSlots = [ownSlot] + spare.prefix(spare.count / 2)
        let grantedChunks = Array(free.prefix(chunks))

        // The child starts on the parent's words, through the parent's keys
        // for the slots it is given. The parent keeps those entries for when
        // the slots come back.
        let header = SpaceHeader(
            masterKey: Self.randomBytes(32), room: grantedChunks,
            slots: grantedSlots, headerChunks: [], files: [], children: [],
            codeWrap: Data(), resetWithRecoveryKey: false,
            recoveryKeys: state.header.recoveryKeys.filter { grantedSlots.contains($0.key) }
        )
        let child = try register(header: header, wrappedBy: key, code: code)
        let childState = try self.state(child)

        let granted = Set(grantedChunks)
        state.header.room.removeAll { granted.contains($0) }
        let gone = Set(grantedSlots)
        state.header.slots.removeAll { gone.contains($0) }
        state.header.children.append(ChildRef(
            name: name, slot: child.slot,
            headerKey: childState.headerKey.withUnsafeBytes { Data($0) },
            headerChunk: childState.header.headerChunks[0],
            grantedChunks: grantedChunks, grantedSlots: grantedSlots
        ))
        try save(state, slot: parent.slot)
        return child
    }

    /// Names of the spaces under `parent`. Spaces that deleted themselves are
    /// dropped and what was granted to them comes back.
    func children(of parent: SpaceRef) throws -> [String] {
        var state = try state(parent)
        var changed = false
        state.header.children.removeAll { ref in
            // Only a header that no longer opens means the child deleted
            // itself; a read error must never hand its room out again.
            do {
                _ = try loadHeader(key: SymmetricKey(data: ref.headerKey), firstChunk: ref.headerChunk)
                return false
            } catch CryptoKitError.authenticationFailure {
            } catch {
                return false
            }
            state.header.room.append(contentsOf: ref.grantedChunks)
            state.header.slots.append(contentsOf: ref.grantedSlots)
            changed = true
            return true
        }
        if changed { try save(state, slot: parent.slot) }
        return state.header.children.map(\.name)
    }

    /// Opens a child without its code; parents hold their children's keys.
    func openChild(of parent: SpaceRef, named name: String) throws -> SpaceRef {
        let state = try state(parent)
        guard let ref = state.header.children.first(where: { $0.name == name }) else {
            throw StorageError.noSuchSpace
        }
        let key = SymmetricKey(data: ref.headerKey)
        let header = try loadHeader(key: key, firstChunk: ref.headerChunk)
        spaces[ref.slot] = SpaceState(header: header, headerKey: key)
        return SpaceRef(slot: ref.slot)
    }

    /// Deletes a child and every space under it. Their room and slots return
    /// to `parent`.
    func deleteChild(of parent: SpaceRef, named name: String) throws {
        var state = try state(parent)
        guard let index = state.header.children.firstIndex(where: { $0.name == name }) else {
            throw StorageError.noSuchSpace
        }
        let ref = state.header.children.remove(at: index)
        var chunks = Set(ref.grantedChunks)
        var slots = Set(ref.grantedSlots)
        try wipeSubtree(ref, reclaimedChunks: &chunks, reclaimedSlots: &slots)
        state.header.room.append(contentsOf: chunks.subtracting(state.header.room))
        state.header.slots.append(contentsOf: slots.subtracting(state.header.slots))
        try save(state, slot: parent.slot)
    }

    /// Deletes this space and every space under it. The parent, if any,
    /// reclaims what it granted the next time it lists its children.
    func deleteSelf(_ ref: SpaceRef) throws {
        let state = try state(ref)
        var chunks = Set<UInt32>()
        var slots = Set<Int>()
        for child in state.header.children {
            try wipeSubtree(child, reclaimedChunks: &chunks, reclaimedSlots: &slots)
        }
        try wipe(state, slot: ref.slot)
        spaces[ref.slot] = nil
    }

    // MARK: Files

    func fileNames(in ref: SpaceRef) throws -> [String] {
        try state(ref).header.files.map(\.name)
    }

    func writeFile(named name: String, data: Data, in ref: SpaceRef) throws {
        try checkItemWrite(name, in: ref)
        var state = try state(ref)
        if state.header.files.contains(where: { $0.name == name }) { try deleteFile(named: name, in: ref); state = try self.state(ref) }
        let needed = max(1, (data.count + Self.chunkPlain - 1) / Self.chunkPlain)
        drawReserve(needed, into: &state)
        let free = state.header.freeChunks
        guard free.count >= needed else { throw StorageError.noRoom }
        let chunks = Array(free.prefix(needed))
        for (i, chunk) in chunks.enumerated() {
            let start = i * Self.chunkPlain
            let end = min(start + Self.chunkPlain, data.count)
            try writeChunk(chunk, plain: data[start..<end], key: state.masterKey)
        }
        state.header.files.append(FileEntry(name: name, size: Int64(data.count), chunks: chunks, created: .now))
        try save(state, slot: ref.slot)
    }

    /// Streams a file in one chunk at a time, so a large video never sits in
    /// memory at once. Used by Save to Casita, whose memory limit is small.
    func writeFile(named name: String, from url: URL, in ref: SpaceRef) throws {
        try checkItemWrite(name, in: ref)
        var state = try state(ref)
        if state.header.files.contains(where: { $0.name == name }) { try deleteFile(named: name, in: ref); state = try self.state(ref) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let needed = max(1, Int((size + Int64(Self.chunkPlain) - 1) / Int64(Self.chunkPlain)))
        drawReserve(needed, into: &state)
        let free = state.header.freeChunks
        guard free.count >= needed else { throw StorageError.noRoom }
        let chunks = Array(free.prefix(needed))
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }
        for chunk in chunks {
            let piece = try source.read(upToCount: Self.chunkPlain) ?? Data()
            try writeChunk(chunk, plain: piece, key: state.masterKey)
        }
        state.header.files.append(FileEntry(name: name, size: size, chunks: chunks, created: .now))
        try save(state, slot: ref.slot)
    }

    func readFile(named name: String, in ref: SpaceRef) throws -> Data {
        let state = try state(ref)
        guard let entry = state.header.files.first(where: { $0.name == name }) else { throw StorageError.noSuchFile }
        var data = Data(capacity: Int(entry.size))
        for chunk in entry.chunks {
            data.append(try readChunk(chunk, key: state.masterKey))
        }
        return data.prefix(Int(entry.size))
    }

    func deleteFile(named name: String, in ref: SpaceRef) throws {
        var state = try state(ref)
        guard let index = state.header.files.firstIndex(where: { $0.name == name }) else { throw StorageError.noSuchFile }
        let entry = state.header.files.remove(at: index)
        for chunk in entry.chunks { try wipeChunk(chunk) }
        try save(state, slot: ref.slot)
    }

    /// Moves reserve chunks into room when the free room is short of
    /// `needed`: what is missing, or half the reserve if that is more.
    private func drawReserve(_ needed: Int, into state: inout SpaceState) {
        let short = needed - state.header.freeChunks.count
        guard short > 0, var reserve = state.header.reserve, !reserve.isEmpty else { return }
        let take = min(reserve.count, max(short, reserve.count / 2))
        state.header.room.append(contentsOf: reserve.suffix(take))
        reserve.removeLast(take)
        state.header.reserve = reserve
    }

    /// Free room in bytes, as this space sees it.
    func freeBytes(in ref: SpaceRef) throws -> Int64 {
        Int64(try state(ref).header.freeChunks.count) * Int64(Self.chunkPlain)
    }

    // MARK: Growing

    /// Grows the file to the next size stop. The new room belongs to `ref`.
    func grow(for ref: SpaceRef) throws {
        guard access.hasPlan else { throw PlanLimit.storage }
        guard let current = StorageSize(rawValue: byteSize), let next = current.next else {
            throw StorageError.alreadyAtMaximum
        }
        try grow(for: ref, toBytes: next.rawValue)
    }

    func grow(for ref: SpaceRef, toBytes bytes: Int64) throws {
        guard access.hasPlan else { throw PlanLimit.storage }
        precondition(bytes > byteSize)
        var state = try state(ref)
        let oldCount = chunkCount
        try Self.fillRandom(handle, from: byteSize, to: bytes)
        byteSize = bytes
        try writeFileHeader()
        state.header.room.append(contentsOf: UInt32(oldCount)..<UInt32(chunkCount))
        try save(state, slot: ref.slot)
    }

    // MARK: Slots

    func slotOpening(with key: SymmetricKey) throws -> (slot: Int, headerKey: SymmetricKey, headerChunk: UInt32)? {
        var found: (Int, SymmetricKey, UInt32)?
        for slot in 0..<Self.slotCount {
            let sealed = try read(at: Self.slotOffset(slot), count: Self.slotSize)
            guard let box = try? AES.GCM.SealedBox(combined: sealed),
                  let plain = try? AES.GCM.open(box, using: key), plain.count == 36
            else { continue }
            // No early exit: every slot is read whatever happens.
            if found == nil {
                let chunk = plain[plain.startIndex + 32..<plain.startIndex + 36].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                found = (slot, SymmetricKey(data: plain.prefix(32)), chunk)
            }
        }
        return found
    }

    private func register(header: SpaceHeader, wrappedBy key: SymmetricKey, code: String) throws -> SpaceRef {
        var header = header
        let slot = header.ownSlot
        let headerKey = SymmetricKey(size: .bits256)
        guard let first = header.freeChunks.first else { throw StorageError.noRoom }
        header.headerChunks = [first]
        header.codeWrap = try AES.GCM.seal(Self.slotPlain(headerKey, first), using: codeWrapKey(code)).combined!
        let state = SpaceState(header: header, headerKey: headerKey)
        try save(state, slot: slot)
        try writeDeviceSlot(slot, headerKey: headerKey, headerChunk: first, under: key)
        try writePortableSlot(slot, for: state)
        return SpaceRef(slot: slot)
    }

    func writeDeviceSlot(_ slot: Int, headerKey: SymmetricKey, headerChunk: UInt32, under key: SymmetricKey) throws {
        try write(try AES.GCM.seal(Self.slotPlain(headerKey, headerChunk), using: key).combined!, at: Self.slotOffset(slot))
    }

    /// Seals `state`'s code wrap and reset part to the recovery key its
    /// header holds for `slot`. A nil `state` seals random bytes instead, so
    /// an unused slot looks like a used one.
    ///
    /// The plain key at the front stays as it is when `state` has no key for
    /// the slot (a space not yet given words, or an unused slot), so a rewrite
    /// changes the same bytes whether or not the slot is in use. `freshKey`
    /// puts a new throwaway key there instead, for a slot being emptied.
    func writePortableSlot(_ slot: Int, for state: SpaceState?, freshKey: Bool = false) throws {
        let publicKey: Curve25519.KeyAgreement.PublicKey
        if let raw = state?.header.recoveryKeys[slot], let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) {
            publicKey = key
        } else if !freshKey, let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: read(at: Self.portableOffset(slot), count: 32)) {
            publicKey = key
        } else {
            publicKey = Self.throwawayPublicKey()
        }
        let plain = if let state { state.header.codeWrap + resetPart(state) } else { Self.randomBytes(Self.portablePlainSize) }
        try write(try Self.portableSlot(slot, publicKey: publicKey, plain: plain), at: Self.portableOffset(slot))
    }

    /// What the words may use to open the space without its code: its header
    /// key and first chunk when its reset switch is on, random bytes when off.
    private func resetPart(_ state: SpaceState) -> Data {
        state.header.resetWithRecoveryKey
            ? Self.slotPlain(state.headerKey, state.header.headerChunks[0])
            : Self.randomBytes(Self.slotPlainSize)
    }

    /// Recovery public key ‖ HPKE seal of `plain` to it.
    static func portableSlot(_ slot: Int, publicKey: Curve25519.KeyAgreement.PublicKey, plain: Data) throws -> Data {
        precondition(plain.count == portablePlainSize)
        return publicKey.rawRepresentation + (try hpkeSeal(plain, to: publicKey, info: portableInfo(slot)))
    }

    static func throwawayPublicKey() -> Curve25519.KeyAgreement.PublicKey {
        Curve25519.KeyAgreement.PrivateKey().publicKey
    }

    /// PBKDF2 of the code without the Secure Enclave, so it can be redone on
    /// another phone. Only reachable behind the recovery words.
    func codeWrapKey(_ code: String) -> SymmetricKey {
        SymmetricKey(data: pbkdf2(Data(code.utf8), salt: portableSalt, iterations: codeWrapIterations))
    }

    static func slotPlain(_ headerKey: SymmetricKey, _ headerChunk: UInt32) -> Data {
        var plain = headerKey.withUnsafeBytes { Data($0) }
        withUnsafeBytes(of: headerChunk.littleEndian) { plain.append(contentsOf: $0) }
        return plain
    }

    static func portableInfo(_ slot: Int) -> Data { Data("casita.portable.\(slot)".utf8) }

    // MARK: Headers

    /// Writes the header into its own chunks, taking more from free room if it
    /// grew. Chunks are chained: each starts with the next chunk's index.
    func save(_ state: SpaceState, slot: Int) throws {
        var state = state
        let encoder = JSONEncoder()
        let dataPerChunk = Self.chunkPlain - 4
        var encoded = Data()
        for _ in 0..<4 {
            encoded = try encoder.encode(state.header)
            let needed = (encoded.count + 4 + dataPerChunk - 1) / dataPerChunk
            if needed <= state.header.headerChunks.count { break }
            let extra = needed - state.header.headerChunks.count
            drawReserve(extra, into: &state)
            let free = state.header.freeChunks
            guard free.count >= extra else { throw StorageError.noRoom }
            state.header.headerChunks.append(contentsOf: free.prefix(extra))
        }
        var payload = Data()
        withUnsafeBytes(of: UInt32(encoded.count).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(encoded)

        let chunks = state.header.headerChunks
        for (i, chunk) in chunks.enumerated() {
            let next = i + 1 < chunks.count ? chunks[i + 1] : Self.endOfChain
            var plain = Data()
            withUnsafeBytes(of: next.littleEndian) { plain.append(contentsOf: $0) }
            let start = min(i * dataPerChunk, payload.count)
            let end = min(start + dataPerChunk, payload.count)
            plain.append(payload[start..<end])
            try writeChunk(chunk, plain: plain, key: state.headerKey)
        }
        spaces[slot] = state
    }

    func loadHeader(key: SymmetricKey, firstChunk: UInt32) throws -> SpaceHeader {
        var payload = Data()
        var next = firstChunk
        var total: Int?
        while next != Self.endOfChain {
            guard Int(next) < chunkCount else { throw StorageError.corruptHeader }
            let plain = try readChunk(next, key: key)
            next = plain.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            payload.append(plain.dropFirst(4))
            if total == nil, payload.count >= 4 {
                total = Int(payload.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            }
            if let total, payload.count - 4 >= total { break }
        }
        guard let total, payload.count - 4 >= total else { throw StorageError.corruptHeader }
        return try JSONDecoder().decode(SpaceHeader.self, from: payload[4..<4 + total])
    }

    func state(_ ref: SpaceRef) throws -> SpaceState {
        guard let state = spaces[ref.slot] else { throw StorageError.noSuchSpace }
        return state
    }

    // MARK: Wiping

    private func wipeSubtree(_ ref: ChildRef, reclaimedChunks: inout Set<UInt32>, reclaimedSlots: inout Set<Int>) throws {
        reclaimedChunks.formUnion(ref.grantedChunks)
        reclaimedSlots.formUnion(ref.grantedSlots)
        let key = SymmetricKey(data: ref.headerKey)
        guard let header = try? loadHeader(key: key, firstChunk: ref.headerChunk) else { return }
        for child in header.children {
            try wipeSubtree(child, reclaimedChunks: &reclaimedChunks, reclaimedSlots: &reclaimedSlots)
        }
        reclaimedChunks.formUnion(header.room + (header.reserve ?? []))
        reclaimedSlots.formUnion(header.slots)
        try wipe(SpaceState(header: header, headerKey: key), slot: ref.slot)
    }

    private func wipe(_ state: SpaceState, slot: Int) throws {
        for chunk in state.header.room + (state.header.reserve ?? []) { try wipeChunk(chunk) }
        try write(Self.randomBytes(Self.slotSize), at: Self.slotOffset(slot))
        try writePortableSlot(slot, for: nil, freshKey: true)
        spaces[slot] = nil
    }

    private func wipeChunk(_ chunk: UInt32) throws {
        try write(Self.randomBytes(Self.chunkSealed), at: Self.chunkOffset(chunk))
    }

    // MARK: Chunk IO

    private func writeChunk(_ chunk: UInt32, plain: Data, key: SymmetricKey) throws {
        precondition(plain.count <= Self.chunkPlain)
        var padded = Data(plain)
        if padded.count < Self.chunkPlain { padded.append(Self.randomBytes(Self.chunkPlain - padded.count)) }
        let sealed = try AES.GCM.seal(padded, using: key).combined!
        try write(sealed, at: Self.chunkOffset(chunk))
    }

    private func readChunk(_ chunk: UInt32, key: SymmetricKey) throws -> Data {
        let sealed = try read(at: Self.chunkOffset(chunk), count: Self.chunkSealed)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }

    static func slotOffset(_ slot: Int) -> UInt64 { UInt64(fileHeaderSize + slot * slotSize) }
    static func portableOffset(_ slot: Int) -> UInt64 { UInt64(portableOffset + slot * portableSlotSize) }
    private static func chunkOffset(_ chunk: UInt32) -> UInt64 { UInt64(chunksOffset) + UInt64(chunk) * UInt64(chunkSealed) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw StorageError.corruptHeader }
        return data
    }

    func write(_ data: Data, at offset: UInt64) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }

    // MARK: File header and random fill

    /// Writes the fixed fields only; the padding stays as it is.
    private static func writeFileHeader(
        _ handle: FileHandle, salt: Data, bytes: Int64,
        publicKey: Curve25519.KeyAgreement.PublicKey, portableSalt: Data
    ) throws {
        var head = magic
        head.append(salt)
        withUnsafeBytes(of: bytes.littleEndian) { head.append(contentsOf: $0) }
        head.append(publicKey.rawRepresentation)
        head.append(portableSalt)
        precondition(head.count == fileHeaderFixed)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: head)
    }

    /// Rewrites magic, salt and size, the fields that can change after
    /// create. The unused key field and the portable salt stay as they are.
    func writeFileHeader() throws {
        var head = Self.magic
        head.append(salt)
        withUnsafeBytes(of: byteSize.littleEndian) { head.append(contentsOf: $0) }
        try write(head, at: 0)
    }

    /// Rewrites the header padding so the file changes on every unlock
    /// attempt, right or wrong.
    private func touchFileHeader() throws {
        try write(Self.randomBytes(Self.fileHeaderSize - Self.fileHeaderFixed), at: UInt64(Self.fileHeaderFixed))
    }

    /// Fills [from, to) with bytes indistinguishable from random, fast enough
    /// for gigabytes: AES-GCM keystream under a throwaway key.
    private static func fillRandom(_ handle: FileHandle, from: Int64, to: Int64) throws {
        let block = 1 << 20
        let zeros = Data(count: block)
        try handle.seek(toOffset: UInt64(from))
        var remaining = to - from
        while remaining > 0 {
            let n = Int(min(Int64(block), remaining))
            let stream = try AES.GCM.seal(zeros.prefix(n), using: SymmetricKey(size: .bits256)).ciphertext
            try handle.write(contentsOf: stream)
            remaining -= Int64(n)
        }
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess)
        return data
    }
}
