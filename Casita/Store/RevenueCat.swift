import Foundation
import RevenueCat

/// Purchases go through RevenueCat. It
/// sees purchase records, an anonymous ID and what the SDK sends with every
/// request (the identifier for vendor, device model, OS, locale, storefront,
/// IP address), never anything about spaces:
/// the subscription is app-wide and Casita sets no user ID. Its one
/// attribute is how far setup got (`SetupFunnel`).
enum RevenueCatConfig {
    /// Public SDK keys, meant to ship in the app. Debug builds use
    /// RevenueCat's Test Store, so purchases work on any iPhone or simulator
    /// before App Store Connect has the products; release builds (TestFlight,
    /// App Store) use the App Store.
    #if DEBUG
    static let apiKey = "test_DcGDZDYsZuDsOuNALISQNemjaJU"
    #else
    static let apiKey = "appl_bAZifWRUisnRXgJjSbpQmRcivHQ"
    #endif
    /// The one entitlement every product unlocks.
    static let entitlement = "casita"

    @MainActor static func configure() {
        guard !Purchases.isConfigured else { return }
        Purchases.logLevel = .warn
        var builder = Configuration.Builder(withAPIKey: apiKey).with(storeKitVersion: .storeKit2)
        #if DEBUG
        // End-to-end tests (`-freshStart`) share one Test Store customer, so
        // a run doesn't make a new anonymous one at every launch. A test that
        // buys asks for its own with
        // `-freshCustomer`, so the shared one never owns a plan. The shipped
        // app still sets no user ID.
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-freshStart"), !args.contains("-freshCustomer") { builder = builder.with(appUserID: testCustomer) }
        #endif
        Purchases.configure(with: builder.build())
    }

    #if DEBUG
    static let testCustomer = "casita-ui-tests"

    /// Restart setup in debug builds: RevenueCat forgets this anonymous
    /// customer and makes a new one, so the Test Store offers the trial
    /// again. Still no app user ID. Release builds keep their customer.
    @MainActor static func startFreshCustomer() {
        let suite = "com.revenuecat.user_defaults"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        // A second configure replaces the shared instance.
        Purchases.configure(with: Configuration.Builder(withAPIKey: apiKey).with(storeKitVersion: .storeKit2).build())
    }
    #endif
}

/// How far setup got, as one RevenueCat customer attribute, `setup_step`:
/// the New Customers chart split by it shows where
/// people stop, and the trial charts filter by it. Setup only: every install
/// walks the same steps with the same two spaces, so nothing about spaces
/// can be read from it, and nothing is sent once setup ends. It only moves
/// forward; RevenueCat sends it with its next request.
enum SetupFunnel {
    enum Step: Int, CaseIterable, Sendable {
        // 9 was a page that is gone; the numbers stay so
        // the chart's segments keep their meaning.
        case welcome1 = 1, welcome2, welcome3, welcome4, everydayCode, privateCode, recoveryWords, fill
        case ageCheck = 10, paywallTrial, paywallPlans, done

        /// "06 privateCode": numbered, so the chart's segments sort in order.
        var value: String { String(format: "%02d ", rawValue) + String(describing: self) }
    }

    static let attribute = "setup_step"
    /// The furthest step sent, app-wide like the subscription.
    static let furthestKey = "setup.furthest"

    @MainActor static func reached(_ step: Step, defaults: UserDefaults = .standard, send: @MainActor (String) -> Void = sendToRevenueCat) {
        guard step.rawValue > defaults.integer(forKey: furthestKey) else { return }
        defaults.set(step.rawValue, forKey: furthestKey)
        send(step.value)
    }

    @MainActor private static func sendToRevenueCat(_ value: String) {
        guard Purchases.isConfigured else { return }
        Purchases.shared.attribution.setAttributes([attribute: value])
    }
}

/// Ownership from RevenueCat's customer info: the product behind the active
/// "casita" entitlement, if any.
struct RevenueCatEntitlementSource: EntitlementSource {
    func ownedProductIDs() async -> Set<String>? {
        guard Purchases.isConfigured, let info = try? await Purchases.shared.customerInfo() else { return nil }
        return Self.owned(info)
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                guard Purchases.isConfigured else { return continuation.finish() }
                for await _ in Purchases.shared.customerInfoStream { continuation.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func owned(_ info: CustomerInfo) -> Set<String> {
        guard let entitlement = info.entitlements[RevenueCatConfig.entitlement], entitlement.isActive else { return [] }
        return [entitlement.productIdentifier]
    }
}

extension PeriodUnit {
    init(_ unit: SubscriptionPeriod.Unit) {
        switch unit {
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        default: self = .year
        }
    }
}

extension IntroOffer {
    init?(_ discount: StoreProductDiscount) {
        let mode: Mode
        switch discount.paymentMode {
        case .freeTrial: mode = .free
        case .payAsYouGo: mode = .payAsYouGo
        case .payUpFront: mode = .payUpFront
        @unknown default: return nil
        }
        self.init(
            mode: mode, price: discount.localizedPriceString, periodValue: discount.subscriptionPeriod.value,
            periodUnit: PeriodUnit(discount.subscriptionPeriod.unit), periods: discount.numberOfPeriods
        )
    }
}
