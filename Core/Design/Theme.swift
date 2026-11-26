import SwiftUI

/// Casita's look in one place: black, flat, two surface greys, white for
/// what matters, gold only where security is the point (lock, shield,
/// recovery words, encryption). No gradients, gloss or glow anywhere.
enum Theme {
    static let background = Color.black
    /// Cards, tiles, list rows.
    static let surface = Color(white: 0.078)
    /// Keys, fields and controls, and anything sitting on a card.
    static let raised = Color(white: 0.13)
    static let hairline = Color.white.opacity(0.09)

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.62)
    /// 0.5 keeps small text above 4.5:1 on black and on cards.
    static let tertiary = Color.white.opacity(0.5)
    /// The grey lead line of a two-tone title.
    static let quiet = Color.white.opacity(0.42)

    /// Security only. #E9B949.
    static let gold = Color(red: 0.914, green: 0.725, blue: 0.286)
    /// Destructive actions. #FF453A.
    static let danger = Color(red: 1.0, green: 0.271, blue: 0.227)

    static let gutter: CGFloat = 24
    static let cardRadius: CGFloat = 24
    static let rowRadius: CGFloat = 18
    static let tileRadius: CGFloat = 24

    /// Taps, toggles and small moves.
    static let snappy = Animation.snappy(duration: 0.3)
    /// Screens and big moves.
    static let smooth = Animation.smooth(duration: 0.55)
    /// Things that arrive: badges, checks, the logo.
    static let bouncy = Animation.bouncy(duration: 0.55, extraBounce: 0.14)
}

extension Font {
    /// Hero lines on onboarding and empty states.
    static let casitaDisplay = Font.system(size: 42, weight: .heavy)
    static let casitaTitle = Font.system(size: 32, weight: .bold)
    static let casitaTitle2 = Font.system(size: 24, weight: .bold)
    /// Section labels.
    static let casitaLabel = Font.footnote.weight(.semibold)
}
