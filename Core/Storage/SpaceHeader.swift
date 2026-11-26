import Foundation

enum StorageError: Error, Equatable {
    case notCasitaFile
    case wrongFileSize
    case codeInUse
    case noRoom
    case noSlots
    case noSuchSpace
    case noSuchFile
    case corruptHeader
    case alreadyAtMaximum
    case stretchFailed
}

/// The sizes reserved storage can have. Everyone's file is one of these, so
/// its size says nothing about what is inside.
enum StorageSize: Int64, CaseIterable, Sendable {
    case mb512 = 536_870_912
    case gb1 = 1_073_741_824
    case gb2 = 2_147_483_648
    case gb4 = 4_294_967_296
    case gb8 = 8_589_934_592
    case gb16 = 17_179_869_184
    case gb32 = 34_359_738_368
    case gb64 = 68_719_476_736
    case gb128 = 137_438_953_472

    static let recommended = StorageSize.gb2

    var next: StorageSize? {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

/// A space as its parent sees it: open to the parent, with its name, only
/// known to the parent.
struct ChildRef: Codable, Equatable, Sendable {
    var name: String
    var slot: Int
    var headerKey: Data
    var headerChunk: UInt32
    /// What the parent handed over, reclaimed if the child vanishes on its own.
    var grantedChunks: [UInt32]
    var grantedSlots: [Int]
}

struct FileEntry: Codable, Equatable, Sendable {
    var name: String
    var size: Int64
    var chunks: [UInt32]
    var created: Date
}

/// Everything a space knows. Encrypted under the space's header key and
/// stored in the space's own chunks. Nothing here points to a parent.
struct SpaceHeader: Codable, Equatable, Sendable {
    var masterKey: Data
    /// Chunks this space owns outright (its room), header chunks included.
    var room: [UInt32]
    /// Slots this space may use; the first is its own.
    var slots: [Int]
    var headerChunks: [UInt32]
    var files: [FileEntry]
    var children: [ChildRef]
    /// Header key and first header chunk under PBKDF2 of this space's code
    /// (no Secure Enclave). What the portable slot seals to the recovery key;
    /// kept here so a space can re-seal the slots of the spaces under it to
    /// new words without knowing their codes.
    var codeWrap: Data
    /// Whether the recovery words this space is sealed to may reset its code.
    /// Every space has its own switch; off by default.
    var resetWithRecoveryKey: Bool
    /// The per-slot recovery public keys of the words this space is sealed
    /// to, for every slot in `givenSlots` and no other. Empty until the space
    /// first gets words. A new child gets the entries for the slots it is
    /// given, so it starts on its parent's words. Holding keys for no slot
    /// outside its own share means a space can't match other slots to its
    /// words.
    var recoveryKeys: [Int: Data]
    /// Room the top space owns but doesn't count as free, so the top, like
    /// every space under it, sees less free room than the file holds. Drawn
    /// on only when its counted room runs out. Nil in every other space.
    var reserve: [UInt32]? = nil

    var ownSlot: Int { slots[0] }

    /// Every slot this space was given: its own, its spare ones and the ones
    /// it handed to children (which come back when they are deleted).
    var givenSlots: Set<Int> {
        Set(slots).union(children.flatMap(\.grantedSlots))
    }

    var freeChunks: [UInt32] {
        var used = Set(headerChunks)
        for file in files { used.formUnion(file.chunks) }
        return room.filter { !used.contains($0) }
    }

    var spareSlots: [Int] { Array(slots.dropFirst()) }
}

/// An opened space. Only valid for the `ReservedStorage` that produced it.
struct SpaceRef: Hashable, Sendable {
    let slot: Int
}

/// Enough to open one space without its code. Kept only in the Keychain
/// behind Face ID, for the everyday space.
struct SpaceCredential: Codable, Sendable {
    var slot: Int
    var headerKey: Data
    var headerChunk: UInt32
}
