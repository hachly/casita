import Foundation
import StoreKit

enum PeriodUnit: Sendable, Equatable {
    case day, week, month, year

    init(_ unit: Product.SubscriptionPeriod.Unit) {
        switch unit {
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        default: self = .year
        }
    }

    var word: String {
        switch self {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .year: "year"
        }
    }

    func count(_ n: Int) -> String { n == 1 ? word : "\(n) \(word)s" }
}

/// An introductory offer as plain values, so the paywall's words can be
/// tested without StoreKit.
struct IntroOffer: Equatable, Sendable {
    enum Mode: Equatable, Sendable { case free, payAsYouGo, payUpFront }
    var mode: Mode
    /// What the offer costs per period (pay as you go) or in total (up front).
    var price: String
    /// One period of the offer, such as 3 days or 1 week.
    var periodValue: Int
    var periodUnit: PeriodUnit
    /// How many periods the offer lasts (pay as you go only; otherwise 1).
    var periods: Int

    init(mode: Mode, price: String, periodValue: Int, periodUnit: PeriodUnit, periods: Int = 1) {
        self.mode = mode
        self.price = price
        self.periodValue = periodValue
        self.periodUnit = periodUnit
        self.periods = periods
    }

    init?(_ offer: Product.SubscriptionOffer) {
        let mode: Mode
        switch offer.paymentMode {
        case .freeTrial: mode = .free
        case .payAsYouGo: mode = .payAsYouGo
        case .payUpFront: mode = .payUpFront
        default: return nil
        }
        self.init(
            mode: mode, price: offer.displayPrice, periodValue: offer.period.value,
            periodUnit: PeriodUnit(offer.period.unit), periods: offer.periodCount
        )
    }

    /// How many units the offer lasts in total.
    var units: Int { mode == .payAsYouGo ? periodValue * periods : periodValue }

    /// "3 days", "week", "2 months": how long the offer lasts in total.
    var length: String { periodUnit.count(units) }
}

/// Every word the paywall shows for one plan: the title, the card and the
/// button. The billed price is the biggest number on the card.
struct PlanTerms: Equatable, Sendable {
    let product: CasitaProduct
    /// The price after any offer.
    let price: String
    /// "/year", "/week", or "once".
    let per: String
    /// The title in two tones: "Start your" / "3-day free trial."
    let lead: String
    let title: String
    /// "3 days", on a free trial only.
    let trial: String?
    /// "No payment due now", on a free trial only.
    let dueNow: String?
    let button: String
    /// The terms under the button.
    let summary: String

    init(product: CasitaProduct, price: String, renewal: PeriodUnit?, intro: IntroOffer?) {
        self.product = product
        self.price = price
        guard let renewal else {
            per = "once"
            (lead, title) = ("Pay once.", "Keep it for good.")
            (trial, dueNow) = (nil, nil)
            button = "Buy for \(price)"
            summary = "One payment of \(price)."
            return
        }
        per = "/\(renewal.word)"
        let then = "then \(price) per \(renewal.word)."
        guard let intro else {
            (lead, title) = ("Unlock", "everything.")
            (trial, dueNow) = (nil, nil)
            button = "Subscribe for \(price)"
            summary = "\(price) per \(renewal.word). Renews until cancelled."
            return
        }
        if intro.mode == .free {
            // "3-day free trial": a trial counted in days, as the App Store sells it.
            let days = intro.periodUnit == .week ? intro.units * 7 : intro.units
            let dayCount = intro.periodUnit == .day || intro.periodUnit == .week
            (lead, title) = ("Start your", dayCount ? "\(days)-day free trial." : "free \(intro.length).")
            (trial, dueNow) = (intro.length, "No payment due now")
            button = dayCount ? "Start my \(days)-day free trial" : "Start my free trial"
            summary = "\(intro.length.prefix(1).uppercased() + intro.length.dropFirst()) free, \(then)"
        } else {
            (lead, title) = ("Your first \(intro.length)", "for \(intro.price).")
            (trial, dueNow) = (nil, nil)
            button = "Start for \(intro.price)"
            summary = "\(intro.price) for the first \(intro.length), \(then)"
        }
    }
}
