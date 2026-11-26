import Foundation

/// What the app and the Save to Casita extension share: the storage file,
/// the wrong-code waits and the Keychain access group.
enum AppGroup {
    static let id = "group.com.hachly.casita"

    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
    /// Whether the store last confirmed a plan, mirrored by the app's
    /// `Entitlements` so the extension can gate adding. Never the tester
    /// unlock: the old key, "subscribed", held tester builds' always-true
    /// value, and a release build installed over one started out unlocked.
    static let ownsPlanKey = "ownsPlan"
    /// Refreshed every few seconds while a space is open in Casita, removed
    /// when it locks. Save to Casita refuses while it is fresh: the open space
    /// keeps its header in memory and would write over what the extension
    /// saved. Says nothing about which space, or how many there are.
    static let spaceOpenKey = "spaceOpenHeartbeat"
    static var spaceOpenInApp: Bool {
        (defaults.object(forKey: spaceOpenKey) as? Date).map { Date.now.timeIntervalSince($0) < 15 } ?? false
    }

    /// The reserved storage file. Falls back to Application Support when the
    /// group container is unavailable (no entitlement yet on a dev build).
    static var storageURL: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("reserved.bin")
    }

    /// Moves a storage file made before the App Group existed.
    static func migrateLegacyStorage() {
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("reserved.bin")
        let current = storageURL
        guard legacy != current, FileManager.default.fileExists(atPath: legacy.path),
              !FileManager.default.fileExists(atPath: current.path) else { return }
        try? FileManager.default.moveItem(at: legacy, to: current)
    }
}

/// iPhone-style waits after wrong codes, shared by the app and the
/// extension. During a wait no code works, the right one included.
///
/// A wait runs on the time since the iPhone started, which keeps counting
/// in sleep and which changing the date in Settings doesn't touch. After a
/// restart that clock begins again, so the wait starts over in full.
///
/// A right code does not clear the count: it falls by one for every hour
/// without a wrong try, on the same clock. Otherwise anyone who can open one
/// space (its code, or the owner's face) could guess at the others for ever,
/// four tries at a time. Only erasing Casita clears it.
struct WrongCodeWaits {
    private static let attemptsKey = "wrongAttempts"
    private static let startKey = "waitStart"
    private static let lengthKey = "waitLength"
    private static let bootKey = "waitBoot"
    /// When the count last changed, and in which boot.
    private static let countedKey = "wrongCounted"
    private static let countedBootKey = "wrongCountedBoot"
    static let secondsPerFall: Double = 3600
    private var defaults: UserDefaults { AppGroup.defaults }

    var waitUntil: Date? {
        let length = defaults.double(forKey: Self.lengthKey)
        guard length > 0 else { return nil }
        let now = Self.uptime
        var start = defaults.double(forKey: Self.startKey)
        if defaults.string(forKey: Self.bootKey) != Self.bootSession || now < start {
            start = now
            defaults.set(start, forKey: Self.startKey)
            defaults.set(Self.bootSession, forKey: Self.bootKey)
        }
        let left = length - (now - start)
        return left > 0 ? Date.now.addingTimeInterval(left) : nil
    }

    var isWaiting: Bool { waitUntil != nil }

    /// The count after `elapsed` seconds without a wrong try, and how many of
    /// those seconds are used up by the tries that fell away.
    static func fallen(_ count: Int, after elapsed: Double) -> (count: Int, used: Double) {
        let falls = min(count, max(0, Int(elapsed / secondsPerFall)))
        return (count - falls, Double(falls) * secondsPerFall)
    }

    /// The wrong tries that still count. A restart keeps them and starts
    /// the hour over.
    private var attempts: Int {
        let stored = defaults.integer(forKey: Self.attemptsKey)
        guard stored > 0 else { return 0 }
        let now = Self.uptime
        var counted = defaults.double(forKey: Self.countedKey)
        if defaults.string(forKey: Self.countedBootKey) != Self.bootSession || now < counted {
            counted = now
            defaults.set(counted, forKey: Self.countedKey)
            defaults.set(Self.bootSession, forKey: Self.countedBootKey)
        }
        let (left, used) = Self.fallen(stored, after: now - counted)
        if left != stored {
            defaults.set(left, forKey: Self.attemptsKey)
            defaults.set(counted + used, forKey: Self.countedKey)
        }
        return left
    }

    func registerWrongAttempt() {
        let attempts = self.attempts + 1
        defaults.set(attempts, forKey: Self.attemptsKey)
        defaults.set(Self.uptime, forKey: Self.countedKey)
        defaults.set(Self.bootSession, forKey: Self.countedBootKey)
        guard attempts >= 5 else { return }
        let minutes: Double = switch attempts - 5 {
        case 0: 1
        case 1: 5
        case 2: 15
        default: 60
        }
        defaults.set(minutes * 60, forKey: Self.lengthKey)
        defaults.set(Self.uptime, forKey: Self.startKey)
        defaults.set(Self.bootSession, forKey: Self.bootKey)
    }

    /// Erasing Casita only; a right code never calls this.
    func reset() {
        for key in [Self.attemptsKey, Self.startKey, Self.lengthKey, Self.bootKey, Self.countedKey, Self.countedBootKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Seconds since the iPhone started, sleep included.
    private static var uptime: Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    /// Changes at every restart.
    private static let bootSession: String = {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()
}
