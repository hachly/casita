import RevenueCat
import SwiftUI

/// Loads the "default" offering and the person's intro offer eligibility.
@MainActor @Observable
final class PaywallStore {
    enum Phase: Equatable { case loading, ready, unavailable }

    var phase: Phase = .loading
    var packages: [CasitaProduct: Package] = [:]
    /// Products whose introductory offer this person can still take (one
    /// per person across the subscription group).
    var introEligible: Set<String> = []
    var selected = CasitaProduct.preselected

    func load() async {
        phase = .loading
        guard Purchases.isConfigured, let offering = await Self.currentOffering() else {
            phase = .unavailable
            return
        }
        var found: [CasitaProduct: Package] = [:]
        // A product without a real price is left out, not shown as free.
        for package in offering.availablePackages where package.storeProduct.price > 0 {
            if let id = CasitaProduct(rawValue: package.storeProduct.productIdentifier) { found[id] = package }
        }
        packages = found
        introEligible = []
        let offers = found.values.map(\.storeProduct).filter { $0.introductoryDiscount != nil }.map(\.productIdentifier)
        // Unknown or unanswered counts as not eligible: the regular price
        // shows, never a trial Apple might not give.
        if !offers.isEmpty, let eligibility = await answer(within: 10, {
            await Purchases.shared.checkTrialOrIntroDiscountEligibility(productIdentifiers: offers)
        }) {
            introEligible = Set(eligibility.filter { $0.value.status == .eligible }.keys)
        }
        if found[selected] == nil, let first = CasitaProduct.allCases.first(where: { found[$0] != nil }) { selected = first }
        phase = found.isEmpty ? .unavailable : .ready
    }

    /// The current offering, given up on after 10 s. A quick failure is
    /// tried once more after 1.5 s; a slow one isn't, since 20 s of loading
    /// is worse than a Try again button.
    private static func currentOffering() async -> Offering? {
        for attempt in 0..<2 {
            let started = ContinuousClock.now
            if let offering = await answer(within: 10, { try? await Purchases.shared.offerings().current }) { return offering }
            guard attempt == 0, ContinuousClock.now - started < .seconds(9) else { return nil }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        return nil
    }

    /// "$0" in the person's App Store currency, for "Continue for $0".
    var zeroPrice: String? {
        guard let formatter = packages[.yearly]?.storeProduct.priceFormatter?.copy() as? NumberFormatter else { return nil }
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: 0)
    }

    /// Yearly against paying weekly for a year, as a whole percentage.
    var yearlySaving: Int? {
        guard let yearly = packages[.yearly]?.storeProduct.price, let weekly = packages[.weekly]?.storeProduct.price,
              weekly > 0 else { return nil }
        let saving = 1 - (yearly as NSDecimalNumber).doubleValue / ((weekly as NSDecimalNumber).doubleValue * 52)
        return saving > 0.05 ? Int((saving * 100).rounded()) : nil
    }

    func terms(_ id: CasitaProduct) -> PlanTerms? {
        guard let product = packages[id]?.storeProduct else { return nil }
        let intro = introEligible.contains(product.productIdentifier) ? product.introductoryDiscount.flatMap(IntroOffer.init) : nil
        return PlanTerms(
            product: id, price: product.localizedPriceString,
            renewal: product.subscriptionPeriod.map { PeriodUnit($0.unit) }, intro: intro
        )
    }
}

/// A dismissible offer during setup or after a requested premium action.
/// Presentation mode is independent of the free path: X is always available.
struct PaywallView: View {
    var onClose: () -> Void
    var onboarding = false
    var reason: PlanLimit?
    @Environment(Entitlements.self) private var entitlements
    @State private var store = PaywallStore()
    @State private var busy = false
    @State private var closed = false
    @State private var note: String?
    @State private var shown = false
    @State private var showPrivacy = false
    /// The App Store took the payment but access isn't confirmed yet: the
    /// button checks again instead of buying a second time.
    @State private var confirming = false
    /// Onboarding opens on the trial page first.
    @State private var onPlans = false

    private var terms: PlanTerms? { store.terms(store.selected) }
    private var showsPlans: Bool { !onboarding || onPlans }

    private var headline: String {
        switch reason {
        case .items: "Keep your whole collection\nprivate."
        case .web: "All your apps.\nYour own private logins."
        case .spaces: "A private space\nfor every part of your life."
        case .storage: "More room for\nwhat matters to you."
        case .automaticBackup: "Keep a backup.\nWithout remembering to."
        case .smartAlbums: "Find your photos.\nSkip the sorting."
        case nil: "Your photos. Your accounts.\nAll in your own space."
        }
    }

    /// Weekly, yearly, lifetime: yearly in the middle.
    private static let order: [CasitaProduct] = [.weekly, .yearly, .lifetime]

    /// Free next to a plan, one row each: what free keeps, what a plan adds.
    /// The row for the limit that opened the paywall stands out.
    struct Compare: Identifiable {
        var glyph: Glyph
        var title: String
        var free: String
        var plan: String
        var limits: [PlanLimit]
        var id: String { title }
    }

    static let compare: [Compare] = [
        Compare(glyph: .photos, title: "Photos and files", free: "50 per space", plan: "No limit", limits: [.items, .smartAlbums]),
        Compare(glyph: .web, title: "App logins", free: "1 app", plan: "All your apps", limits: [.web]),
        Compare(glyph: .spaces, title: "Spaces and room", free: "2 spaces", plan: "More of both", limits: [.spaces, .storage]),
        Compare(glyph: .cloud, title: "Backups", free: "By hand", plan: "Automatic", limits: [.automaticBackup]),
    ]

    var body: some View {
        ZStack {
            if showsPlans {
                plansPage.transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)).combined(with: .opacity))
            } else {
                trialPage.transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
            }
        }
        // Setup's paywall only: the add gate's never reports.
        .onChange(of: onPlans) { _, on in if on, onboarding { SetupFunnel.reached(.paywallPlans) } }
        .overlay(alignment: .topLeading) {
            if onboarding && onPlans {
                topButton("chevron.left", label: "Back", id: "paywall.back") { withAnimation(Theme.smooth) { onPlans = false } }
                    .disabled(busy)
                    .padding(.leading, Theme.gutter - 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Purchase results still update shared ownership if X is used
            // while the store is waiting. Reads never trap the free path.
            topButton("xmark", label: "Close", id: "paywall.close", action: close)
                .padding(.trailing, Theme.gutter - 4)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .sheet(isPresented: $showPrivacy) { PrivacyView(showsClose: true).presentationBackground(Theme.background) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.screen")
        .task {
            shown = true
            await store.load()
        }
    }

    // MARK: Pages

    /// Page one, in onboarding: the house acts out the two codes over the
    /// trial, and the way on.
    private var trialPage: some View {
        WideReader { split in
            if let split {
                // A wide screen: the house on the leading half, the words
                // and the button on the trailing half.
                HStack(spacing: 0) {
                    HouseScene(story: .twoCodes)
                        .frame(width: split)
                        .frame(maxHeight: 440)
                    VStack(spacing: 0) {
                        Spacer(minLength: 44)
                        trialTitle
                        Spacer(minLength: 16)
                        seePlans
                    }
                    .column()
                }
            } else {
                VStack(spacing: 0) {
                    HouseScene(story: .twoCodes)
                        .frame(maxWidth: .infinity)
                        .frame(height: 400)
                    trialTitle
                    Spacer(minLength: 16)
                    seePlans
                }
                .column()
            }
        }
    }

    private var trialTitle: some View {
        TwoToneTitle(lead: "Improve your privacy", key: "today with Casita.", font: .system(size: 32, weight: .bold), alignment: .center)
            .frame(maxWidth: .infinity)
    }

    /// "No payment due now" belongs beside the button that starts the
    /// trial, on the next page.
    private var seePlans: some View {
        Button("See plans") { withAnimation(Theme.smooth) { onPlans = true } }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("paywall.intro.continue")
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 8)
    }

    /// Page two, and the only page from an add gate: what Casita gives,
    /// then the plans in a row, yearly in the middle, and the button.
    private var plansPage: some View {
        WideReader { split in
            if let split {
                // A wide screen: what Casita gives on the leading half, the
                // plans and the button on the trailing half, centred against
                // the pitch so neither half leaves an empty band.
                HStack(spacing: 0) {
                    pitch
                        .padding(.horizontal, Theme.gutter)
                        .padding(.vertical, 44)
                        .frame(width: split)
                    VStack(spacing: 12) {
                        Spacer(minLength: 44)
                        plans(stacked: true)
                        purchase
                        links
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.gutter)
                    .column()
                }
                .padding(.bottom, 8)
            } else {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 44)
                    pitch
                    VStack(spacing: 12) {
                        plans(stacked: false)
                        purchase
                        links
                    }
                    .padding(.top, 12)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 8)
                .column()
            }
        }
    }

    /// The mark, the headline and the benefits. What's left over on a tall
    /// iPhone is shared out above and below, never left as one band above
    /// the plans.
    private var pitch: some View {
            GeometryReader { room in
                // Short room (a closed iPhone Duo): smaller mark, headline and
                // rows, so the whole comparison shows above the plans.
                let compact = room.size.height < 420
                ScrollView {
                    VStack(spacing: 0) {
                        CasitaMark(style: .onDark).frame(width: compact ? 40 : 64, height: compact ? 40 : 64).reveal(0, active: shown)
                        Text(headline)
                            .font(.system(size: compact ? 22 : 28, weight: .bold)).tracking(-0.6)
                            .multilineTextAlignment(.center)
                            .padding(.top, compact ? 10 : 20)
                            .reveal(1, active: shown)
                        compareTable(compact: compact)
                            .reveal(2, active: shown)
                            .padding(.top, compact ? 12 : 24)
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: room.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
    }

    // MARK: Parts

    /// What free keeps beside what a plan adds. Free is quiet, the plan is
    /// white, so the eye lands on the plan. Columns take the width their words
    /// need. The larger font is used only when every row fits on one line;
    /// otherwise the smaller one, and past that a long row name wraps rather
    /// than being cut. `compact` is for short screens (a closed iPhone Duo).
    private func compareTable(compact: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            compareGrid(font: .subheadline, compact: compact)
            compareGrid(font: .footnote, compact: compact)
        }
        .padding(.horizontal, compact ? 12 : 14)
        .padding(.vertical, compact ? 6 : 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("paywall.compare")
    }

    private func compareGrid(font: Font, compact: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: compact ? 6 : 10, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: 20, height: 1)
                Color.clear.frame(height: 1)
                Text("Free").foregroundStyle(Theme.tertiary)
                Text("Plan").foregroundStyle(Theme.primary)
            }
            .font(.footnote.weight(.semibold))
            .padding(.bottom, compact ? 4 : 8)
            .accessibilityHidden(true)
            ForEach(Self.compare) { row in
                let picked = reason.map(row.limits.contains) ?? false
                // Modifiers on a GridRow go to each cell, so the row's label sits
                // on the name and the other cells are hidden from VoiceOver.
                GridRow {
                    GlyphView(glyph: row.glyph, lineWidth: 1.7).frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text(row.title).font(font.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .gridColumnAlignment(.leading)
                        .accessibilityLabel("\(row.title): free, \(row.free); with a plan, \(row.plan)")
                    // Large text: every column wraps rather than one being cut.
                    Text(row.free).font(font).foregroundStyle(Theme.tertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                    Text(row.plan).font(font.weight(.semibold))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, compact ? 7 : 11)
                .anchorPreference(key: PickedRow.self, value: .bounds) { picked ? [$0] : [] }
            }
        }
        // One band behind the whole row the paywall opened for, drawn from
        // the cells' combined bounds.
        .backgroundPreferenceValue(PickedRow.self) { cells in
            GeometryReader { proxy in
                if let first = cells.first {
                    let rect = cells.dropFirst().reduce(proxy[first]) { $0.union(proxy[$1]) }
                    RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                        .fill(Theme.raised)
                        .frame(width: proxy.size.width + 20, height: rect.height)
                        .offset(x: -10, y: rect.minY)
                }
            }
        }
    }

    private func topButton(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(symbol == "xmark" ? Color.clear : Theme.raised))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func select(_ id: CasitaProduct) {
        guard store.selected != id, store.packages[id] != nil else { return }
        Haptics.play(.select)
        withAnimation(Theme.snappy) { store.selected = id }
    }

    /// The three plans side by side, or one row each beside the pitch on a
    /// wide screen (an open iPhone Duo), where a row is easier to reach and
    /// read; or why they can't show.
    @ViewBuilder private func plans(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        switch store.phase {
        case .loading:
            layout {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface).frame(height: stacked ? 60 : 96)
                }
            }
            .padding(.top, 10)
            .phaseAnimator([0.5, 1]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.8) }
        case .unavailable:
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Can't reach the App Store right now.").foregroundStyle(Theme.secondary)
                    Button("Try again") { Task { await store.load() } }
                        .buttonStyle(RaisedButtonStyle())
                        .accessibilityIdentifier("paywall.retry")
                }
            }
        case .ready:
            layout {
                ForEach(Self.order, id: \.self) { id in
                    if let terms = store.terms(id) {
                        Button { select(id) } label: {
                            if stacked {
                                PlanRow(terms: terms, selected: store.selected == id, badge: badge(id, terms))
                            } else {
                                PlanCard(terms: terms, selected: store.selected == id, badge: badge(id, terms))
                            }
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.97))
                        // The App Store sheet is buying the plan picked before.
                        .disabled(busy || confirming)
                        .accessibilityAddTraits(store.selected == id ? .isSelected : [])
                        .accessibilityIdentifier("paywall.plan.\(id.name.lowercased())")
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    /// "3 days free" on a yearly trial, otherwise what yearly saves.
    private func badge(_ id: CasitaProduct, _ terms: PlanTerms) -> String? {
        guard id == .yearly else { return nil }
        if let trial = terms.trial { return "\(trial) free" }
        return store.yearlySaving.map { "Save \($0)%" }
    }

    /// The button, with "No payment due now" above it and the terms below;
    /// only "Continue" once the person has a plan.
    private var purchase: some View {
        VStack(spacing: 12) {
            if entitlements.ownsPlan {
                Button("Continue", action: close)
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("paywall.continue")
            } else {
                Label(terms?.dueNow ?? " ", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .opacity(terms?.dueNow == nil ? 0 : 1)
                    .accessibilityHidden(terms?.dueNow == nil)
                Button(busy ? "Waiting for the App Store…" : confirming ? "Check again" : (terms?.button ?? "Continue")) {
                    Task { await buy() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(terms == nil || busy)
                .accessibilityIdentifier("paywall.buy")
                Text(note ?? terms?.summary ?? " ")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(note == nil ? Theme.tertiary : Theme.secondary)
            }
        }
        .transaction { $0.animation = nil }
    }

    /// Restore, Terms and Privacy; tester builds add a way past.
    private var links: some View {
        HStack(spacing: 22) {
            Button("Restore") { Task { await restore() } }.disabled(busy).accessibilityIdentifier("paywall.restore")
            Link("Terms", destination: StoreLinks.terms)
            Button("Privacy") { showPrivacy = true }.accessibilityIdentifier("paywall.privacy")
            #if TESTER
            // Tester builds show the real paywall but must never trap a
            // tester whose TestFlight App Store doesn't answer.
            Button("Skip (tester build)", action: close)
            #endif
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(Theme.tertiary)
    }

    private func buy() async {
        guard !busy, let package = store.packages[store.selected] else { return }
        busy = true
        note = nil
        defer { busy = false }
        if confirming {
            await entitlements.refresh()
            if entitlements.ownsPlan { finish() } else { note = Self.unconfirmed }
            return
        }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return }
            await take(result.customerInfo)
            if entitlements.ownsPlan {
                finish()
            } else {
                confirming = true
                note = Self.unconfirmed
            }
        } catch let error as RevenueCat.ErrorCode where error == .paymentPendingError {
            note = "Waiting for approval. Premium opens up as soon as it's approved."
        } catch let error as RevenueCat.ErrorCode where error == .networkError || error == .offlineConnectionError {
            note = Self.offline
        } catch {
            Haptics.play(.error)
            note = "The purchase didn't go through."
        }
    }

    private func restore() async {
        guard !busy else { return }
        busy = true
        note = nil
        defer { busy = false }
        do {
            await take(try await Purchases.shared.restorePurchases())
            if entitlements.ownsPlan { finish() } else { note = "Nothing to restore on this Apple Account." }
        } catch {
            // Not "nothing to restore": the App Store never answered.
            note = Self.offline
        }
    }

    /// What a purchase or restore reported. When it shows no plan yet, the
    /// store is asked once more rather than taken at its word.
    private func take(_ info: CustomerInfo) async {
        let ids = RevenueCatEntitlementSource.owned(info)
        if ids.isEmpty { await entitlements.refresh() } else { entitlements.update(ids) }
    }

    private func finish() {
        guard !closed else { return }
        Haptics.play(.success)
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        onClose()
    }

    private static let unconfirmed = "Payment received. Casita is still confirming it; tap Check again in a moment."
    private static let offline = "Couldn't reach the App Store. Try again in a moment."
}

/// `work`'s answer, or nil once `seconds` pass first, so a store call that
/// never returns can't hold the paywall.
@MainActor
func answer<T: Sendable>(within seconds: Double, _ work: @escaping @MainActor () async -> T?) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let first = FirstAnswer(continuation)
        Task { @MainActor in first.give(await work()) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            first.give(nil)
        }
    }
}

@MainActor
private final class FirstAnswer<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }

    func give(_ value: T?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// One of three plans side by side: its name, the billed price, the period.
private struct PlanCard: View {
    let terms: PlanTerms
    let selected: Bool
    let badge: String?

    var body: some View {
        VStack(spacing: 4) {
            Text(terms.product.name).font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Theme.primary : Theme.secondary)
            Text(terms.price).font(.system(size: 17, weight: .bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(terms.per).font(.caption).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(selected ? Theme.raised : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(selected ? Color.white : Theme.hairline, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .top) {
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(selected ? Color.white : Theme.raised))
                    .foregroundStyle(selected ? Color.black : Theme.secondary)
                    .offset(y: -10)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// One plan as a row: its name and badge on the left, the billed price and
/// period on the right.
private struct PlanRow: View {
    let terms: PlanTerms
    let selected: Bool
    let badge: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(terms.product.name).font(.body.weight(.semibold))
                .foregroundStyle(selected ? Theme.primary : Theme.secondary)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(selected ? Color.white : Theme.raised))
                    .foregroundStyle(selected ? Color.black : Theme.secondary)
            }
            Spacer(minLength: 8)
            Text(terms.price).font(.system(size: 17, weight: .bold)).monospacedDigit()
                .lineLimit(1)
            Text(terms.per).font(.subheadline).foregroundStyle(Theme.tertiary)
                .frame(minWidth: 44, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 60)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(selected ? Theme.raised : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(selected ? Color.white : Theme.hairline, lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Presents the paywall from anywhere, after the age check where the law
/// asks for one. Use with a paid feature or a storage allowance error:
///
///     if entitlements.allows(.createSpace) { create() } else { showPaywall = true }
///     ...
///     .paywall(isPresented: $showPaywall)
extension View {
    func paywall(isPresented: Binding<Bool>, reason: PlanLimit? = nil) -> some View {
        fullScreenCover(isPresented: isPresented) {
            PaywallGate(onClose: { isPresented.wrappedValue = false }, reason: reason)
        }
    }
}

private struct PaywallGate: View {
    var onClose: () -> Void
    var reason: PlanLimit?
    @State private var needsAgeCheck: Bool?

    var body: some View {
        Group {
            switch needsAgeCheck {
            case nil: Color.black.ignoresSafeArea()
            case true?: AgeCheckView { needsAgeCheck = false }
            case false?: PaywallView(onClose: onClose, reason: reason)
            }
        }
        .task {
            needsAgeCheck = AgeCheck.confirmedAdult ? false : await AgeCheck.isRequired()
        }
        .overlay(alignment: .topTrailing) {
            if needsAgeCheck != false {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondary).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                .accessibilityIdentifier("paywall.close")
                .padding(.trailing, Theme.gutter - 4)
            }
        }
    }
}

/// The cells of the comparison row the paywall opened for.
private struct PickedRow: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}
