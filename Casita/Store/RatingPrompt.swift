import Foundation

/// When to ask for an App Store rating: never in setup (App Store
/// guideline 5.6.3), only once Casita has been used for a while, and at most
/// once. App-wide, like every setting seen from outside a space: it counts
/// opens of any space and never which one, so it says nothing about spaces.
enum RatingPrompt {
    static let opensKey = "rating.opens"
    static let firstOpenKey = "rating.firstOpen"
    static let askedKey = "rating.asked"
    static let opensBefore = 6
    static let daysBefore = 3.0

    /// A space just opened, by code or Face ID.
    static func spaceOpened(defaults: UserDefaults = .standard, now: Date = .now) {
        if defaults.object(forKey: firstOpenKey) == nil { defaults.set(now, forKey: firstOpenKey) }
        defaults.set(defaults.integer(forKey: opensKey) + 1, forKey: opensKey)
    }

    /// Whether to ask now; true at most once. iOS still decides whether the
    /// prompt shows.
    static func takeTurn(defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        guard !defaults.bool(forKey: askedKey),
              defaults.integer(forKey: opensKey) >= opensBefore,
              let first = defaults.object(forKey: firstOpenKey) as? Date,
              now.timeIntervalSince(first) >= daysBefore * 86_400 else { return false }
        defaults.set(true, forKey: askedKey)
        return true
    }
}
