import Foundation

/// How Casita locks, and how the entry screen feels. App-wide: their effect
/// can be seen from outside a space, so every space has the same values.
/// The defaults need no setup.
struct LockSettings: Equatable, Sendable {
    enum Gesture: String, CaseIterable, Sendable { case flip, twoFingerDoubleTap, off }

    /// The auto-lock choices, in seconds without touches.
    static let idleChoices = [30, 60, 300]
    /// How long after a lock the same space reopens where it was, in
    /// minutes; 0 is off.
    static let reopenChoices = [0, 1, 5, 15]

    var idleSeconds = 60
    var reopenMinutes = 5
    var gesture: Gesture = .flip
    var hideDotsLine = false
    var haptics = true
    /// A foldable iPhone (iPhone Duo): closing it locks an open space. Off by
    /// default: closed, the space carries on on the outer screen.
    var lockWhenClosed = false
}

/// Keeps `LockSettings` in UserDefaults under one fixed set of keys for the
/// whole app. Nothing is stored per space, so nothing here can say how many
/// spaces exist or which one changed a setting.
struct LockSettingsStore {
    enum Key {
        static let idleSeconds = "lock.idleSeconds"
        static let gesture = "lock.gesture"
        static let hideDotsLine = "lock.hideDotsLine"
        static let haptics = "lock.haptics"
        static let reopenMinutes = "lock.reopenMinutes"
        static let lockWhenClosed = "lock.whenClosed"
        static let all = [idleSeconds, gesture, hideDotsLine, haptics, reopenMinutes, lockWhenClosed]
    }

    let defaults: UserDefaults

    static var standard: LockSettingsStore { LockSettingsStore(defaults: AppGroup.defaults) }

    /// Unknown or missing values fall back to the defaults.
    func load() -> LockSettings {
        var settings = LockSettings()
        if let idle = defaults.object(forKey: Key.idleSeconds) as? Int, LockSettings.idleChoices.contains(idle) {
            settings.idleSeconds = idle
        }
        if let raw = defaults.string(forKey: Key.gesture), let gesture = LockSettings.Gesture(rawValue: raw) {
            settings.gesture = gesture
        }
        if let hide = defaults.object(forKey: Key.hideDotsLine) as? Bool { settings.hideDotsLine = hide }
        if let haptics = defaults.object(forKey: Key.haptics) as? Bool { settings.haptics = haptics }
        if let minutes = defaults.object(forKey: Key.reopenMinutes) as? Int, LockSettings.reopenChoices.contains(minutes) {
            settings.reopenMinutes = minutes
        }
        if let closed = defaults.object(forKey: Key.lockWhenClosed) as? Bool { settings.lockWhenClosed = closed }
        return settings
    }

    func save(_ settings: LockSettings) {
        defaults.set(settings.idleSeconds, forKey: Key.idleSeconds)
        defaults.set(settings.gesture.rawValue, forKey: Key.gesture)
        defaults.set(settings.hideDotsLine, forKey: Key.hideDotsLine)
        defaults.set(settings.haptics, forKey: Key.haptics)
        defaults.set(settings.reopenMinutes, forKey: Key.reopenMinutes)
        defaults.set(settings.lockWhenClosed, forKey: Key.lockWhenClosed)
    }
}
