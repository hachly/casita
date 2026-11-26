import Foundation

/// Purchase state is app-wide; usage is read only from the unlocked space.
enum StorageAccess: Sendable {
    case unrestricted, free, purchases

    var hasPlan: Bool {
        switch self {
        case .unrestricted: return true
        case .free: return false
        case .purchases:
            #if TESTER
            return true
            #else
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-devSubscribed") { return true }
            #endif
            return AppGroup.defaults.bool(forKey: AppGroup.ownsPlanKey)
            #endif
        }
    }
}

enum PlanLimit: Error, Equatable, Sendable, LocalizedError {
    case items, spaces, storage, web, automaticBackup, smartAlbums

    var errorDescription: String? {
        switch self {
        case .items: "This space has reached its 50-item free allowance. Upgrade to keep adding."
        case .spaces: "Upgrade to create another space."
        case .storage: "Upgrade to make more room."
        case .web: "Keep one app's logins free. Upgrade to keep all your apps here."
        case .automaticBackup: "Upgrade for automatic iCloud backups. Manual backups stay available."
        case .smartAlbums: "Upgrade to sort photos automatically."
        }
    }
}

enum FreePlan {
    static let itemLimit = 50
    /// From this many items a space's main screen says how many more fit.
    static let headsUpAt = 40

    /// "42 of 50 on Free", under the Photos and Files titles.
    static func countLine(used: Int) -> String { "\(used) of \(itemLimit) on Free" }

    /// The note above Lock once a space nears the free allowance; nil below it.
    static func headsUp(used: Int) -> String? {
        guard used >= headsUpAt else { return nil }
        let left = max(0, itemLimit - used)
        switch left {
        case 0: return "\(itemLimit) of \(itemLimit) on Free. See plans to keep adding."
        case 1: return "1 more photo or file fits on Free. See plans"
        default: return "\(left) more photos or files fit on Free. See plans"
        }
    }

    static func isUserItem(_ name: String) -> Bool {
        !name.contains("/") && !name.hasSuffix(".thumb")
    }
}

extension ReservedStorage {
    @discardableResult
    func addUserFile(named proposed: String, data: Data, in ref: SpaceRef) throws -> String {
        let name = try availableUserFileName(proposed, in: ref)
        try writeFile(named: name, data: data, in: ref)
        return name
    }

    @discardableResult
    func addUserFile(named proposed: String, from url: URL, in ref: SpaceRef) throws -> String {
        let name = try availableUserFileName(proposed, in: ref)
        try writeFile(named: name, from: url, in: ref)
        return name
    }

    func availableUserFileName(_ proposed: String, in ref: SpaceRef) throws -> String {
        var name = proposed.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        if name.isEmpty { name = "File" }
        if name.hasSuffix(".thumb") { name += ".file" }
        let existing = Set(try fileNames(in: ref))
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name, suffix = 2
        while existing.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    func userItemCount(in ref: SpaceRef) throws -> Int {
        try state(ref).header.files.filter { FreePlan.isUserItem($0.name) }.count
    }

    func checkCanAddItem(in ref: SpaceRef) throws {
        if !access.hasPlan, try userItemCount(in: ref) >= FreePlan.itemLimit { throw PlanLimit.items }
    }

    /// Called inside the same actor turn as the actual write, including
    /// batch imports and extension writes. Replacing an existing item is free.
    func checkItemWrite(_ name: String, in ref: SpaceRef) throws {
        let header = try state(ref).header
        if FreePlan.isUserItem(name), !header.files.contains(where: { $0.name == name }) {
            try checkCanAddItem(in: ref)
        }
    }
}
