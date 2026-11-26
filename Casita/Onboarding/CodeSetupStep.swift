import SwiftUI

/// What a new code must be, per unlock method. The entry screen accepts
/// whatever a code was set to; these rules apply only when setting one.
enum CodeRules {
    static let minimumDigits = 6
    static let minimumDots = 4
    static let minimumPasswordLength = 6

    /// Why `code` can't be used, or nil when it can.
    static func problem(with code: String, method: EntryView.Method) -> String? {
        switch method {
        case .numbers:
            code.count < minimumDigits ? "Use at least \(minimumDigits) digits." : nil
        case .dots:
            (DotsCode.dotCount(code) ?? 0) < minimumDots ? "Join at least \(minimumDots) dots." : nil
        case .letters:
            code.count < minimumPasswordLength ? "Use at least \(minimumPasswordLength) characters." : nil
        }
    }
}

/// Steps 2 and 3, each in three parts: what this code is for, acted out by
/// the house; then just the unlock method and the code, entered twice (a
/// match draws a check, a mismatch shakes); then a short "set" page.
struct CodeSetupStep: View {
    enum Kind { case everyday, `private` }

    let kind: Kind
    @Bindable var flow: OnboardingModel
    var onDone: () -> Void
    var onBack: () -> Void

    @Environment(\.onboardingCompact) private var compact
    @Environment(AppModel.self) private var app
    @State private var method: EntryView.Method = .numbers
    @State private var dotsGrid = 3
    @State private var entered = ""
    @State private var first: String?
    @State private var message: String?
    @State private var shake = 0
    @State private var matched = false
    /// Bumped on every submit so the password field comes back focused.
    @State private var attempt = 0
    /// The page that says what this code is for comes first.
    @State private var introDone = false
    /// The private code's Continue sets the storage aside; no page of its own.
    @State private var creating = false
    @State private var createProblem: String?

    private var saved: String? {
        get { kind == .everyday ? flow.everydayCode : flow.privateCode }
        nonmutating set {
            if kind == .everyday { flow.everydayCode = newValue } else { flow.privateCode = newValue }
        }
    }

    private var name: String { kind == .everyday ? "everyday" : "private" }

    var body: some View {
        ZStack {
            if saved != nil {
                done.transition(.opacity)
            } else if introDone {
                entry.transition(.opacity)
            } else {
                intro.transition(.opacity)
            }
        }
        .animation(Theme.smooth, value: saved != nil)
        .animation(Theme.smooth, value: introDone)
        .alert("Casita couldn't set up", isPresented: Binding(get: { createProblem != nil }, set: { if !$0 { createProblem = nil } })) {
            Button("Try again") { Task { await finishPrivate() } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(createProblem ?? "")
        }
    }

    // MARK: Intro

    private var intro: some View {
        OnboardingPage(
            id: "onboarding.code.\(name).intro",
            title: kind == .everyday ? "Everyday code" : "Private code",
            text: kind == .everyday ? "It opens a space you can show to anyone." : "It opens a hidden space. Use a different code.",
            primary: kind == .everyday ? "Set everyday code" : "Set private code",
            action: { introDone = true },
            onBack: onBack,
            artHeight: 300
        ) {
            HouseScene(story: kind == .everyday ? .everyday : .private)
        } content: {
            EmptyView()
        }
    }

    // MARK: Entry

    private var entry: some View {
        OnboardingPage(id: "onboarding.code.\(name)", title: entryTitle, onBack: { introDone = false }, artHeight: 0) {
            EmptyView()
        } content: {
            VStack(spacing: compact ? 10 : 14) {
                // The second entry uses the method of the first.
                MethodPicker(method: $method)
                    .onChange(of: method) { entered = ""; first = nil; message = nil; matched = false }
                    .opacity(first == nil ? 1 : 0)
                    .allowsHitTesting(first == nil)
                    .accessibilityHidden(first != nil)
                    .animation(Theme.snappy, value: first == nil)
                VStack(spacing: 8) {
                    status.frame(height: 30)
                    Text(message ?? " ")
                        .font(.footnote.weight(message == nil ? .regular : .semibold))
                        .foregroundStyle(message == nil ? Theme.tertiary : Theme.primary)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 18)
                        .contentTransition(.opacity)
                        .animation(Theme.snappy, value: message)
                        .accessibilityIdentifier("onboarding.code.message")
                }
                .modifier(ShakeOnChange(trigger: shake))
                Spacer(minLength: 4)
                pad
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var entryTitle: String {
        if first != nil { return "Enter it again." }
        return kind == .everyday ? "Choose your everyday code." : "Choose your private code."
    }

    /// The typed digits; a check once the second entry matches.
    @ViewBuilder private var status: some View {
        ZStack {
            if matched {
                CheckBadge(drawn: true, size: 30)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else if method == .numbers {
                SetupCodeDots(count: entered.count)
                    .transition(.opacity)
                    .accessibilityIdentifier("onboarding.code.dots")
            }
        }
        .animation(Theme.bouncy, value: matched)
    }

    @ViewBuilder private var pad: some View {
        Group {
            switch method {
            case .numbers:
                NumberPad(entered: $entered, onSubmit: { submit(entered) }, onFaceID: faceIDKey)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("onboarding.code.pad")
            case .dots:
                VStack(spacing: compact ? 10 : 16) {
                    GridSizePicker(size: $dotsGrid)
                        .opacity(first == nil ? 1 : 0)
                        .allowsHitTesting(first == nil)
                        .accessibilityHidden(first != nil)
                    DotsPad(gridSize: dotsGrid, hideLine: false, onSubmit: { submit($0) })
                        .accessibilityIdentifier("onboarding.dots.pad")
                }
            case .letters:
                PasswordField(text: $entered, onSubmit: { submit(entered) })
                    .id(attempt)
                    .accessibilityIdentifier("onboarding.code.field")
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(matched)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .animation(Theme.snappy, value: method)
    }

    /// Sets aside the storage and makes both spaces, then moves on.
    private func finishPrivate() async {
        creating = true
        let problem = await flow.createSpaces(app: app)
        creating = false
        if let problem {
            Haptics.play(.error)
            createProblem = problem
        } else {
            Haptics.play(.success)
            onDone()
        }
    }

    private func faceIDKey() {
        message = kind == .everyday
            ? "Face ID can open this space. Turn it on next."
            : "Face ID never opens this space."
    }

    private func submit(_ code: String) {
        guard !matched else { return }
        entered = ""
        attempt += 1
        if let problem = CodeRules.problem(with: code, method: method) {
            message = problem
            shake += 1
            Haptics.play(.warning)
            return
        }
        if kind == .private, code == flow.everydayCode {
            message = "That's your everyday code. Choose a different one."
            shake += 1
            Haptics.play(.warning)
            return
        }
        guard let first else {
            message = nil
            withAnimation(Theme.smooth) { self.first = code }
            Haptics.play(.soft)
            return
        }
        if code == first {
            message = nil
            matched = true
            Haptics.play(.success)
            Task {
                try? await Task.sleep(for: .milliseconds(750))
                saved = code
            }
        } else {
            withAnimation(Theme.smooth) { self.first = nil }
            message = "Those didn't match. Start again."
            shake += 1
            Haptics.play(.error)
        }
    }

    // MARK: Done

    private var done: some View {
        OnboardingPage(
            id: "onboarding.code.\(name).set",
            lead: kind == .everyday ? "Everyday code set." : "Private code set.",
            title: kind == .private ? "Face ID never opens it." : "Now let's do a private one.",
            primary: creating ? "Setting up…" : "Continue",
            primaryDisabled: creating,
            action: kind == .private ? { Task { await finishPrivate() } } : onDone,
            // Stays in place while setting up, so nothing moves; does nothing then.
            secondary: PageAction("Change code", id: "onboarding.code.change") {
                guard !creating else { return }
                first = nil
                matched = false
                saved = nil
            },
            onBack: creating ? nil : onBack,
            artHeight: 120
        ) {
            DrawnCheck(size: compact ? 64 : 88)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } content: {
            if kind == .everyday, OnboardingModel.biometricsAvailable {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $flow.useFaceID) {
                            Text("Open with Face ID").font(.body.weight(.semibold))
                        }
                        .toggleStyle(CasitaToggleStyle())
                        .accessibilityIdentifier("onboarding.faceid.toggle")
                        Text("Only this space. Only when you tap the Face ID key.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// A check that draws itself shortly after it appears.
struct DrawnCheck: View {
    var size: CGFloat
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        CheckBadge(drawn: drawn || reduceMotion, size: size, tint: tint)
            .task {
                try? await Task.sleep(for: .milliseconds(180))
                drawn = true
            }
    }
}
