import Foundation
import Observation

/// Where ownership comes from: RevenueCat in the app, a fake in tests.
protocol EntitlementSource: Sendable {
    /// Product IDs the person owns right now, or nil when the store
    /// couldn't say (offline, server down).
    func ownedProductIDs() async -> Set<String>?
    /// Yields whenever ownership may have changed.
    func changes() -> AsyncStream<Void>
}

/// Feature gates. Storage enforces the free item allowance at each write;
/// access to existing content and recovery never depends on a subscription.
enum SpaceAction: Sendable, CaseIterable {
    case unlock, view, export
    /// Import entry points; the storage actor checks the remaining allowance.
    case add
    /// Explicitly deleting originals from Photos after a successful import.
    case deleteOriginals
    case createSpace, growStorage, automaticBackup, smartAlbums
}

/// Whether this person has Casita: any active subscription or Lifetime.
/// One per app, app-wide; nothing in it differs between spaces.
@MainActor @Observable
final class Entitlements {
    static let shared = Entitlements(source: RevenueCatEntitlementSource())

    private(set) var owned: Set<String> = []
    /// False until the first read of the source finishes.
    private(set) var loaded = false
    /// What the last launch knew, until the store answers: a paying
    /// person keeps paid access while the store is unavailable.
    @ObservationIgnored private let lastKnown = AppGroup.defaults.bool(forKey: AppGroup.ownsPlanKey)

    @ObservationIgnored private let source: any EntitlementSource
    @ObservationIgnored private var listener: Task<Void, Never>?

    init(source: any EntitlementSource) {
        self.source = source
    }

    /// Whether premium features are available: a plan, or a tester build.
    var isSubscribed: Bool {
        #if TESTER
        // Tester builds open every gate, so every screen can be tried
        // whatever TestFlight's App Store does. Archived with TESTER for
        // TestFlight only; the App Store build never has it.
        return true
        #else
        return ownsPlan
        #endif
    }

    /// Whether the store says this person has a plan. The paywall goes by
    /// this, so tester builds still show the real plans and button.
    var ownsPlan: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-devSubscribed") { return true }
        #endif
        return loaded ? !owned.isDisjoint(with: CasitaProduct.ids) : lastKnown
    }

    /// Screens check premium features before presenting their actions.
    func allows(_ action: SpaceAction) -> Bool {
        switch action {
        case .unlock, .view, .export, .add, .deleteOriginals: true
        case .createSpace, .growStorage, .automaticBackup, .smartAlbums: isSubscribed
        }
    }

    /// Starts listening for transaction updates and reads current
    /// ownership. Call once at launch; later calls do nothing.
    func start() {
        guard listener == nil else { return }
        let changes = source.changes()
        listener = Task { [weak self] in
            for await _ in changes { await self?.refresh() }
        }
        Task { await refresh() }
    }

    /// Reads the store again. An unanswered read keeps what was known.
    /// Listens to the current store again, after RevenueCat was configured
    /// anew (Restart setup in debug builds), and reads ownership.
    func restart() {
        listener?.cancel()
        listener = nil
        start()
    }

    func refresh() async {
        guard let ids = await source.ownedProductIDs() else { return }
        update(ids)
    }

    /// Ownership the store just reported, such as in a purchase result.
    func update(_ ids: Set<String>) {
        owned = ids
        loaded = true
        AppGroup.defaults.set(ownsPlan, forKey: AppGroup.ownsPlanKey)
    }
}
