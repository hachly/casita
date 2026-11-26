import SwiftUI
import Testing
@testable import Casita

/// Sizes measured on the iPhone Duo simulator (iOS 27.1), 23 Nov 2026.
struct AdaptiveTests {
    private let bar = EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)

    @Test func phonesAndTheClosedDuoKeepOneColumn() {
        #expect(Adaptive.split(size: CGSize(width: 402, height: 778), insets: EdgeInsets()) == nil)
        #expect(Adaptive.split(size: CGSize(width: 382, height: 644), insets: bar) == nil)
    }

    @Test func theOpenDuoUprightKeepsOneColumn() {
        #expect(Adaptive.split(size: CGSize(width: 669, height: 835), insets: EdgeInsets(top: 82, leading: 0, bottom: 34, trailing: 0)) == nil)
    }

    /// The scene is 951 pt wide; its middle, the fold, is at 475.5 whichever
    /// side the system bar is on.
    @Test func theOpenDuoSplitsAtTheFold() {
        #expect(Adaptive.split(size: CGSize(width: 867, height: 635), insets: bar) == 475.5)
        let barLeading = EdgeInsets(top: 0, leading: 84, bottom: 34, trailing: 0)
        #expect(Adaptive.split(size: CGSize(width: 867, height: 635), insets: barLeading) == 391.5)
    }
}
