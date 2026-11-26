import SwiftUI

/// Plain steps for opening Casita in one press. Casita can't switch any of
/// these on itself; the same guide is offered once after setup.
struct OpenFasterGuide: View {
    struct Guide: Identifiable {
        let title: String
        let symbol: String
        let steps: [String]
        var id: String { title }
    }

    static let guides: [Guide] = [
        Guide(title: "Action Button", symbol: "button.horizontal.top.press", steps: [
            "Open the iPhone's Settings and tap Action Button.",
            "Swipe to Controls, tap Choose a Control, and pick Casita.",
            "Press and hold the Action Button to open Casita.",
        ]),
        Guide(title: "Lock Screen control", symbol: "lock.iphone", steps: [
            "On the Lock Screen, touch and hold an empty spot, then tap Customize.",
            "Tap Lock Screen.",
            "Tap the minus on one of the controls at the bottom, then tap the empty spot it leaves.",
            "Find Casita, tap it, then tap Done.",
        ]),
        Guide(title: "Focus page", symbol: "moon", steps: [
            "Make a Home Screen page with Casita's widget on it: touch and hold the Home Screen, tap Edit, then Add Widget, and pick Casita.",
            "Open the iPhone's Settings, tap Focus, tap the plus button, then Custom, and name it Casita.",
            "Under Customize Screens, tap the Home Screen and choose only the page with Casita's widget.",
            "Turn the Casita Focus on from Control Center whenever you want that page.",
        ]),
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let shown = appeared || reduceMotion
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Each takes a minute in iPhone Settings.")
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .reveal(0, active: shown)
                ForEach(Array(Self.guides.enumerated()), id: \.element.id) { index, guide in
                    Card(padding: 20) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 14) {
                                Image(systemName: guide.symbol)
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(width: 36, height: 36)
                                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised))
                                Text(guide.title).font(.casitaTitle2).tracking(-0.4)
                            }
                            ForEach(Array(guide.steps.enumerated()), id: \.offset) { number, step in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text("\(number + 1)")
                                        .font(.footnote.weight(.bold).monospacedDigit())
                                        .foregroundStyle(Theme.primary)
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(Theme.raised))
                                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                                    Text(step)
                                        .foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .reveal(index + 1, active: shown)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings.openFaster.\(index)")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .readableColumn()
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .navigationTitle("Open Casita faster")
        .toolbarTitleDisplayMode(.inline)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.openFaster.screen")
    }
}
