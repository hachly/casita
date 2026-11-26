import SwiftUI

/// A text button under a page's main action.
struct PageAction {
    var title: String
    var id: String
    var action: () -> Void

    init(_ title: String, id: String, action: @escaping () -> Void) {
        self.title = title
        self.id = id
        self.action = action
    }
}

/// One onboarding screen: a back key, an illustration that gives way first
/// on short screens, a two-tone title, the step's own content, and the main
/// action at the bottom. Centred: a short page sits in the middle, a long
/// one fills the screen. Everything arrives in a short stagger.
struct OnboardingPage<Art: View, Content: View>: View {
    var id: String
    var lead: String?
    var title: String
    var text: String?
    var primary: String?
    var primaryDisabled: Bool
    var primaryID: String
    var action: () -> Void
    var secondary: PageAction?
    var onBack: (() -> Void)?
    var artHeight: CGFloat
    var art: Art
    var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingCompact) private var compact
    @State private var shown = false

    init(id: String, lead: String? = nil, title: String, text: String? = nil,
         primary: String? = nil, primaryDisabled: Bool = false, primaryID: String = "onboarding.continue",
         action: @escaping () -> Void = {}, secondary: PageAction? = nil, onBack: (() -> Void)? = nil,
         artHeight: CGFloat = 0, @ViewBuilder art: () -> Art, @ViewBuilder content: () -> Content) {
        self.id = id
        self.lead = lead
        self.title = title
        self.text = text
        self.primary = primary
        self.primaryDisabled = primaryDisabled
        self.primaryID = primaryID
        self.action = action
        self.secondary = secondary
        self.onBack = onBack
        self.artHeight = artHeight
        self.art = art()
        self.content = content()
    }

    private var visible: Bool { shown || reduceMotion }

    var body: some View {
        WideReader { split in
            if let split { sideBySide(split) } else { stacked }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
        .onAppear { shown = true }
    }

    private var stacked: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if artHeight > 0 {
                art
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: compact ? artHeight * 0.62 : artHeight)
                    .layoutPriority(1)
                    .reveal(0, active: visible)
            }
            heading
                .reveal(1, active: visible)
            // Ahead of the spacer above the buttons, so a scrolling list
            // reaches down to them.
            content
                .layoutPriority(0.5)
                .reveal(2, active: visible)
            Spacer(minLength: 12)
            if primary != nil || secondary != nil {
                buttons
                    .reveal(3, active: visible)
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 12)
        .column()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A wide screen: the illustration (or, without one, the title) on the
    /// leading half; the title, the step's content and its actions on the
    /// trailing half, under the thumb.
    private func sideBySide(_ split: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if artHeight > 0 {
                    art
                        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: artHeight)
                        .reveal(0, active: visible)
                } else {
                    heading
                        .reveal(1, active: visible)
                }
                Spacer(minLength: 0)
                // Balances the back key, so the art sits in the middle.
                Color.clear.frame(height: compact ? 40 : 44)
            }
            .padding(.horizontal, Theme.gutter)
            .frame(width: split)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if artHeight > 0 {
                    heading
                        .reveal(1, active: visible)
                }
                content
                    .layoutPriority(0.5)
                    .reveal(2, active: visible)
                Spacer(minLength: 12)
                if primary != nil || secondary != nil {
                    buttons
                        .reveal(3, active: visible)
                }
            }
            // Clear of the back key's row and the setup progress line.
            .padding(.top, compact ? 40 : 44)
            .padding(.horizontal, Theme.gutter)
            .column()
        }
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.surface))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.88))
                .accessibilityLabel("Back")
                .accessibilityIdentifier("onboarding.back")
                .transition(.opacity)
            }
            Spacer()
        }
        .frame(height: compact ? 40 : 44)
    }

    private var heading: some View {
        VStack(spacing: compact ? 8 : 12) {
            // Old and new titles cross in place when the step's title changes.
            ZStack(alignment: .top) {
                TwoToneTitle(lead: lead, key: title, font: compact ? .casitaTitle2 : .casitaTitle, alignment: .center)
                    .id((lead ?? "") + "\n" + title)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }
            .frame(maxWidth: .infinity)
            .animation(Theme.smooth, value: (lead ?? "") + title)
            if let text {
                Text(text)
                    .font(compact ? .subheadline : .body)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(Theme.smooth, value: text)
            }
        }
        .padding(.top, compact ? 4 : 10)
        .padding(.bottom, compact ? 14 : 22)
    }

    private var buttons: some View {
        VStack(spacing: 4) {
            if let primary {
                Button(action: action) {
                    Text(primary).contentTransition(.opacity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(primaryDisabled)
                .accessibilityIdentifier(primaryID)
            }
            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier(secondary.id)
            }
        }
        .animation(Theme.snappy, value: primary)
    }
}

extension OnboardingPage where Art == EmptyView {
    init(id: String, lead: String? = nil, title: String, text: String? = nil,
         primary: String? = nil, primaryDisabled: Bool = false, primaryID: String = "onboarding.continue",
         action: @escaping () -> Void = {}, secondary: PageAction? = nil, onBack: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(id: id, lead: lead, title: title, text: text, primary: primary, primaryDisabled: primaryDisabled,
                  primaryID: primaryID, action: action, secondary: secondary, onBack: onBack, artHeight: 0,
                  art: { EmptyView() }, content: content)
    }
}
