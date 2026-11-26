import Foundation

/// What Casita sells. Both subscriptions sit in one subscription group, so a
/// person gets one introductory offer across the two.
///
/// Sold through RevenueCat (offering "default", entitlement "casita"); debug
/// builds buy from RevenueCat's Test Store. `Support/Casita.storekit` is the
/// App Store Connect spec, checked by `StoreKitConfigurationTests`.
enum CasitaProduct: String, CaseIterable, Sendable {
    /// $39.99 a year, 3 days free. Preselected on the paywall.
    case yearly = "com.hachly.casita.yearly"
    /// $4.99 a week, first week $0.99.
    case weekly = "com.hachly.casita.weekly"
    /// $79.99 once (non-consumable).
    case lifetime = "com.hachly.casita.lifetime"

    static let subscriptionGroupName = "Casita"
    static let preselected = CasitaProduct.yearly
    static var ids: Set<String> { Set(allCases.map(\.rawValue)) }

    var name: String {
        switch self {
        case .yearly: "Yearly"
        case .weekly: "Weekly"
        case .lifetime: "Lifetime"
        }
    }

    var isSubscription: Bool { self != .lifetime }
}

enum StoreLinks {
    /// Apple's standard licence agreement, which App Store Connect uses when
    /// no custom one is set. Privacy is an in-app page (`PrivacyView`), so it
    /// works offline and never depends on a website; it links the full
    /// policy, the URL set in App Store Connect, as guideline 3.1.2 asks.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyPolicy = URL(string: "https://www.hachlyai.com/privacy-policy")!
}
