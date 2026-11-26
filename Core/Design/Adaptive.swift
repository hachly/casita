import SwiftUI

/// Layout for wide screens, such as the inner screen of an open iPhone Duo.
/// Decided by the space a view is given, never by the device: closed, a Duo
/// is a phone, and Casita lays out the way it does on any iPhone.
enum Adaptive {
    /// Phone-sized content (setup pages, lists, sheets) is never wider than
    /// this. A wide screen centres it.
    static let column: CGFloat = 480
    /// Lists and settings read best no wider than this.
    static let readable: CGFloat = 680
    /// Two panes go side by side when there is at least this much width and
    /// more width than height. An open Duo held upright gives a tall screen,
    /// which keeps one centred column.
    static let twoPaneWidth: CGFloat = 700

    /// The leading pane's width, or nil when one column fits better. The
    /// panes split at the middle of the whole scene, not at the middle of the
    /// safe area. On a Duo that middle is the fold, so neither pane crosses
    /// it, and the system's side bar only narrows the pane it sits on.
    static func split(size: CGSize, insets: EdgeInsets) -> CGFloat? {
        guard size.width >= twoPaneWidth, size.width > size.height else { return nil }
        // The scene's middle is the fold on an open Duo. A foldable
        // with an off-centre fold would need UIHingeInteraction here.
        return (size.width + insets.leading + insets.trailing) / 2 - insets.leading
    }
}

/// Measures the space it is given and passes `split` (see `Adaptive.split`)
/// to its content: a width means two panes side by side, nil one column.
struct WideReader<Content: View>: View {
    @ViewBuilder var content: (_ split: CGFloat?) -> Content

    var body: some View {
        GeometryReader { geometry in
            content(Adaptive.split(size: geometry.size, insets: geometry.safeAreaInsets))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

extension View {
    /// Centres the view in a column no wider than `width`. On a phone the
    /// column is wider than the screen, so nothing changes.
    func column(_ width: CGFloat = Adaptive.column) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

extension View {
    /// Keeps a scroll view's content in a centred column no wider than
    /// `width`. The scroll view stays full width, so it scrolls from anywhere.
    /// Apply to the ScrollView.
    func readableColumn(_ width: CGFloat = Adaptive.readable) -> some View {
        modifier(ReadableColumn(width: width))
    }
}

/// The width comes from the space offered, never from the scroll view, so
/// the margin can't feed back into what it is measured from. (Measuring the
/// scroll view itself looped forever on Settings on an open iPhone Duo.)
private struct ReadableColumn: ViewModifier {
    var width: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content.contentMargins(.horizontal, max(0, (geometry.size.width - width) / 2), for: .scrollContent)
        }
    }
}
