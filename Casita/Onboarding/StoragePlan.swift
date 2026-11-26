import Foundation

/// Which reserved storage sizes this iPhone can take right now.
enum StoragePlan {
    /// Room left for iOS and other apps after Casita takes its share.
    static let headroom: Int64 = 1 << 30

    /// Every stop that fits in `available` with `headroom` to spare. All of
    /// them when free space can't be read; creation then reports any shortfall.
    static func sizes(available: Int64?) -> [StorageSize] {
        guard let available else { return StorageSize.allCases }
        return StorageSize.allCases.filter { $0.rawValue + headroom <= available }
    }

    /// Under this much free, a space offers to make more room.
    static let lowRoom: Int64 = 100 * 1_048_576

    /// The next stop "Make more room" would grow to, if it fits.
    static func growth(from current: StorageSize, available: Int64?) -> StorageSize? {
        guard let next = current.next else { return nil }
        guard let available else { return next }
        return next.rawValue - current.rawValue + headroom <= available ? next : nil
    }

    /// Free space for important data on the volume holding Casita's storage.
    @MainActor
    static func availableBytes() -> Int64? {
        let url = AppModel.storageURL.deletingLastPathComponent()
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func label(_ size: StorageSize) -> String {
        let gb = size.rawValue >> 30
        return gb == 0 ? "\(size.rawValue >> 20) MB" : "\(gb) GB"
    }

    /// "126 GB", "512 MB": whole numbers, which read calmer than 126.22 GB.
    static func label(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: bytes)
    }
}
