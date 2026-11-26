import SwiftUI

/// Exactly what Casita keeps, what leaves the iPhone, and its limits, in
/// a few plain lines. Opened from Settings and from the paywall's Privacy
/// link; it needs no network, so the link always works.
struct PrivacyView: View {
    var showsClose = false
    @Environment(\.dismiss) private var dismiss
    @State private var shown = false

    private struct Section: Identifiable {
        let glyph: Glyph
        let title: String
        let lines: [String]
        var gold = false
        var id: String { title }
    }

    private static let sections: [Section] = [
        Section(glyph: .lock, title: "Stays on this iPhone",
                lines: ["Everything you add is encrypted with AES-256.", "Your codes and recovery sentence are never stored.",
                        "Photos are sorted into people, places and things on this iPhone."], gold: true),
        Section(glyph: .shield, title: "Never collected",
                lines: ["No account, ads or tracking. No analytics after setup."]),
        Section(glyph: .cloud, title: "What leaves this iPhone",
                lines: ["Backups, if on: locked to your recovery sentence, in your iCloud Drive.",
                        "Purchases: paid through Apple. RevenueCat checks your plan with your purchase records, a random ID, a device ID only our apps see, the iPhone model, region and IP address. During setup it also learns how far you got, never anything after.",
                        "Web: sites see you as in any browser. Searches go to DuckDuckGo."]),
        Section(glyph: .house, title: "What we see",
                lines: ["Nothing in your spaces. We can't recover a code or your words."]),
        Section(glyph: .key, title: "Limits",
                lines: ["Screenshots can't be blocked.", "6-digit codes only slow a forensic lab down.",
                        "Photos keeps deleted originals until you empty Recently Deleted.",
                        "Your recovery sentence plus a backup let someone guess codes on a computer."]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if showsClose {
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                                .frame(width: 36, height: 36).background(Circle().fill(Theme.raised))
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("privacy.close")
                    }
                }
                TwoToneTitle(lead: "Your privacy.", key: "Exactly how it works.")
                    .padding(.bottom, 8)
                    .reveal(0, active: shown)
                ForEach(Array(Self.sections.enumerated()), id: \.element.id) { index, section in
                    Card {
                        HStack(alignment: .top, spacing: 14) {
                            GlyphView(glyph: section.glyph, lineWidth: 1.7).frame(width: 24, height: 24)
                                .foregroundStyle(section.gold ? Theme.gold : Theme.primary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.title).font(.headline)
                                ForEach(section.lines, id: \.self) { line in
                                    Text(line).font(.subheadline).foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .reveal(index + 1, active: shown)
                }
                HStack(spacing: 22) {
                    Link("Full privacy policy", destination: StoreLinks.privacyPolicy)
                        .accessibilityIdentifier("privacy.policy")
                    Link("Terms of use", destination: StoreLinks.terms)
                        .accessibilityIdentifier("privacy.terms")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 6)
                // GeoNames' licence (CC BY 4.0) asks for this credit.
                Link("Place names: GeoNames (geonames.org), CC BY 4.0, shortened.", destination: URL(string: "https://www.geonames.org")!)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiary)
                    .accessibilityIdentifier("privacy.geonames")
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .readableColumn()
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .onAppear { shown = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy.screen")
    }
}
