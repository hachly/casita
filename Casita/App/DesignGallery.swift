#if DEBUG
import SwiftUI

/// `-designGallery`: the logo intro, glyphs and components on one screen,
/// for checking the look in the simulator. Debug builds only.
struct DesignGallery: View {
    @State private var replay = false
    @State private var toast: String?
    @State private var grid = 3
    @State private var paywall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HouseScene(story: .twoCodes).frame(height: 300).accessibilityIdentifier("gallery.house")
                CasitaMarkIntro(play: !replay).frame(height: 170).onTapGesture { replay.toggle() }
                HStack(spacing: 18) {
                    CasitaMark(style: .onDark).frame(width: 64, height: 64)
                    CasitaMark(style: .onLight).frame(width: 64, height: 64).background(RoundedRectangle(cornerRadius: 16).fill(.white))
                }
                TwoToneTitle(lead: "One code for what you show.", key: "Another for what you don't.")
                SectionLabel("Glyphs")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                    ForEach(Glyph.allCases, id: \.self) { glyph in
                        GlyphView(glyph: glyph).frame(width: 28, height: 28)
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                    }
                }
                SectionLabel("Rows")
                CasitaRow(glyph: .lock, title: "Auto-lock", detail: "After 1 minute")
                CasitaRow(glyph: .shield, title: "Recovery key", detail: "Make a new one", tint: Theme.gold)
                Card { Text("A card holds grouped things.").foregroundStyle(Theme.secondary) }
                DotsGridPicker(size: $grid)
                Button("Show paywall") { paywall = true }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("gallery.paywall")
                Button("Primary") { toast = "Saved to this space" }.buttonStyle(PrimaryButtonStyle())
                Button("Raised") {}.buttonStyle(RaisedButtonStyle())
                Button("Delete space") {}.buttonStyle(RaisedButtonStyle(destructive: true))
                Button("Not now") {}.buttonStyle(SecondaryButtonStyle())
            }
            .padding(Theme.gutter)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.primary)
        .toast($toast)
        .paywall(isPresented: $paywall)
    }
}
#endif
