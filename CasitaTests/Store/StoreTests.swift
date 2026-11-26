import Foundation
import StoreKit
import StoreKitTest
import Synchronization
import Testing
@testable import Casita

/// Ownership set by the test (nil: the store didn't answer); `set` also
/// announces a change.
private final class FakeEntitlementSource: EntitlementSource {
    private let owned: Mutex<Set<String>?>
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(_ owned: Set<String>? = []) {
        self.owned = Mutex(owned)
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func ownedProductIDs() async -> Set<String>? { owned.withLock { $0 } }
    func changes() -> AsyncStream<Void> { stream }

    func set(_ new: Set<String>?) {
        owned.withLock { $0 = new }
        continuation.yield()
    }
}

@MainActor @Suite struct EntitlementGateTests {
    @Test func freePlanKeepsCoreActionsOpen() async {
        let entitlements = Entitlements(source: FakeEntitlementSource())
        await entitlements.refresh()
        #expect(entitlements.loaded)
        #expect(!entitlements.isSubscribed)
        #expect(entitlements.allows(.unlock))
        #expect(entitlements.allows(.view))
        #expect(entitlements.allows(.export))
        #expect(!entitlements.allows(.createSpace))
        #expect(entitlements.allows(.deleteOriginals))
        #expect(entitlements.allows(.add))
        #expect(!entitlements.allows(.growStorage))
        #expect(!entitlements.allows(.automaticBackup))
        #expect(!entitlements.allows(.smartAlbums))
    }

    @Test(arguments: CasitaProduct.allCases)
    func anyPlanOpensEverything(_ product: CasitaProduct) async {
        let entitlements = Entitlements(source: FakeEntitlementSource([product.rawValue]))
        await entitlements.refresh()
        #expect(entitlements.isSubscribed)
        for action in SpaceAction.allCases { #expect(entitlements.allows(action), "\(action)") }
    }

    @Test func productsThatArentCasitasDontCount() async {
        let entitlements = Entitlements(source: FakeEntitlementSource(["com.example.other"]))
        await entitlements.refresh()
        #expect(!entitlements.allows(.createSpace))
    }

    @Test func followsChangesAfterStart() async throws {
        let source = FakeEntitlementSource()
        let entitlements = Entitlements(source: source)
        entitlements.start()
        try await waitFor { entitlements.loaded }
        #expect(!entitlements.allows(.createSpace))

        source.set([CasitaProduct.yearly.rawValue])
        try await waitFor { entitlements.isSubscribed }
        #expect(entitlements.allows(.add))

        // Expired or refunded: back to read-only, nothing hidden.
        source.set([])
        try await waitFor { !entitlements.isSubscribed }
        #expect(entitlements.allows(.view))
        #expect(entitlements.allows(.export))
        #expect(!entitlements.allows(.createSpace))
    }

    @Test func anUnansweredReadKeepsWhatWasKnown() async {
        // Offline, a paying person keeps adding, and a lapsed one stays read-only.
        let source = FakeEntitlementSource([CasitaProduct.yearly.rawValue])
        let entitlements = Entitlements(source: source)
        await entitlements.refresh()
        source.set(nil)
        await entitlements.refresh()
        #expect(entitlements.isSubscribed)
        source.set([])
        await entitlements.refresh()
        source.set(nil)
        await entitlements.refresh()
        #expect(!entitlements.isSubscribed)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

@Suite struct PlanTermsTests {
    @Test func yearlyLeadsWithTheThreeDayTrial() {
        let terms = PlanTerms(
            product: .yearly, price: "$39.99", renewal: .year,
            intro: IntroOffer(mode: .free, price: "$0.00", periodValue: 3, periodUnit: .day)
        )
        #expect(terms.price == "$39.99")
        #expect(terms.per == "/year")
        #expect(terms.title == "3-day free trial.")
        #expect(terms.trial == "3 days")
        #expect(terms.dueNow == "No payment due now")
        #expect(terms.button == "Start my 3-day free trial")
        #expect(terms.summary == "3 days free, then $39.99 per year.")
    }

    @Test func weeklyLeadsWithItsFirstWeek() {
        let terms = PlanTerms(
            product: .weekly, price: "$4.99", renewal: .week,
            intro: IntroOffer(mode: .payAsYouGo, price: "$0.99", periodValue: 1, periodUnit: .week, periods: 1)
        )
        #expect(terms.price == "$4.99")
        #expect(terms.lead == "Your first week")
        #expect(terms.title == "for $0.99.")
        #expect(terms.dueNow == nil)
        #expect(terms.button == "Start for $0.99")
        #expect(terms.summary == "$0.99 for the first week, then $4.99 per week.")
    }

    @Test func withoutAnOfferThePlanIsJustThePrice() {
        // One introductory offer per person per group: after the trial is
        // used, neither subscription shows one.
        let terms = PlanTerms(product: .weekly, price: "$4.99", renewal: .week, intro: nil)
        #expect(terms.trial == nil)
        #expect(terms.button == "Subscribe for $4.99")
        #expect(terms.summary == "$4.99 per week. Renews until cancelled.")
    }

    @Test func lifetimeNeverRenews() {
        let terms = PlanTerms(product: .lifetime, price: "$79.99", renewal: nil, intro: nil)
        #expect(terms.per == "once")
        #expect(terms.button == "Buy for $79.99")
        #expect(!terms.summary.contains("Renews"))
    }

    @MainActor @Test func yearlyIsPreselected() {
        #expect(CasitaProduct.preselected == .yearly)
        #expect(PaywallStore().selected == .yearly)
    }
}

/// Checks `Support/Casita.storekit`, the spec for the App Store Connect products.
/// Reads the file from this Mac's checkout, so it runs in the simulator only.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil))
struct StoreKitConfigurationTests {
    private static let configuration = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Support/Casita.storekit")

    private func session() throws -> SKTestSession {
        let session = try SKTestSession(contentsOf: Self.configuration)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    @Test func theThreeProductsMatchThePlan() async throws {
        let session = try session()
        defer { _ = session }
        let products = try await Product.products(for: CasitaProduct.allCases.map(\.rawValue))
        let byID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })

        let yearly = try #require(byID[CasitaProduct.yearly.rawValue])
        #expect(yearly.price == Decimal(string: "39.99"))
        #expect(yearly.subscription?.subscriptionPeriod == .yearly)
        let trial = try #require(yearly.subscription?.introductoryOffer)
        #expect(trial.paymentMode == .freeTrial)
        #expect(trial.period == Product.SubscriptionPeriod.everyThreeDays)

        let weekly = try #require(byID[CasitaProduct.weekly.rawValue])
        #expect(weekly.price == Decimal(string: "4.99"))
        #expect(weekly.subscription?.subscriptionPeriod == .weekly)
        let firstWeek = try #require(weekly.subscription?.introductoryOffer)
        #expect(firstWeek.paymentMode == .payAsYouGo)
        #expect(firstWeek.price == Decimal(string: "0.99"))
        #expect(firstWeek.period == .weekly)
        #expect(firstWeek.periodCount == 1)

        #expect(yearly.subscription?.subscriptionGroupID == weekly.subscription?.subscriptionGroupID)

        let lifetime = try #require(byID[CasitaProduct.lifetime.rawValue])
        #expect(lifetime.type == .nonConsumable)
        #expect(lifetime.price == Decimal(string: "79.99"))
    }
}

@MainActor @Suite struct SetupFunnelTests {
    @Test func onlyEverMovesForwardAndSortsInOrder() throws {
        let defaults = try #require(UserDefaults(suiteName: "SetupFunnelTests"))
        defaults.removePersistentDomain(forName: "SetupFunnelTests")
        var sent: [String] = []
        for step in [SetupFunnel.Step.welcome1, .welcome2, .welcome1, .privateCode, .everydayCode, .paywallPlans, .done, .welcome4] {
            SetupFunnel.reached(step, defaults: defaults) { sent.append($0) }
        }
        #expect(sent == ["01 welcome1", "02 welcome2", "06 privateCode", "12 paywallPlans", "13 done"])
        #expect(SetupFunnel.Step.allCases.map(\.value) == SetupFunnel.Step.allCases.map(\.value).sorted())
    }

    @Test func everySetupStepHasAFunnelStep() {
        let steps = OnboardingStep.allCases.compactMap(\.funnel)
        #expect(steps.count == OnboardingStep.allCases.count - 1, "Only the welcome step reports through its pages")
        #expect(steps == steps.sorted { $0.rawValue < $1.rawValue })
    }
}
