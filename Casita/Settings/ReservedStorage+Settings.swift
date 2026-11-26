import CryptoKit
import Foundation

/// Read-only questions Settings asks about the open space. Each looks only
/// at the space itself and what is under it, never above or beside it.
extension ReservedStorage {
    /// How many spaces are under `ref`, at any depth, for the delete warning.
    /// Spaces that already deleted themselves don't count.
    func spaceCount(under ref: SpaceRef) throws -> Int {
        try spaceCount(under: state(ref).header)
    }

    private func spaceCount(under header: SpaceHeader) -> Int {
        header.children.reduce(0) { total, child in
            guard let childHeader = try? loadHeader(key: SymmetricKey(data: child.headerKey), firstChunk: child.headerChunk) else {
                return total
            }
            return total + 1 + spaceCount(under: childHeader)
        }
    }

    /// Whether the recovery sentence may reset this space's code (opt-in, off by default).
    func resetsWithRecoveryKey(_ ref: SpaceRef) throws -> Bool {
        try state(ref).header.resetWithRecoveryKey
    }
}
