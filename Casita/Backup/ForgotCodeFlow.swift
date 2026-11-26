import SwiftUI

/// "Forgot code?" from the entry screen: give a space a new code with the
/// recovery sentence (only if its reset switch was turned on), continue a
/// backup restore with the original code, or erase and start over.
struct ForgotCodeFlow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .choose
    @State private var phrase = ""
    @State private var method = EntryView.Method.numbers
    @State private var code = ""
    @State private var first: String?
    @State private var problem: String?
    @State private var working = false
    @State private var erasing = false
    @State private var recovery: RecoveryRequest?

    private struct RecoveryRequest: Identifiable {
        let id = UUID()
        let storage: ReservedStorage
    }

    enum Stage { case choose, words, code, done }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch stage {
            case .choose: choose
            case .words: wordsStep
            case .code: codeStep
            case .done: done
            }
        }
        .foregroundStyle(Theme.primary)
        .animation(Theme.smooth, value: stage)
        .fullScreenCover(isPresented: $erasing) {
            StartOverSheet(haptics: app.haptics) {
                dismiss()
                app.startOver()
            }
        }
        .fullScreenCover(item: $recovery) { request in
            RestoreFlow(onCancel: { recovery = nil }, existingStorage: request.storage)
        }
    }

    private var choose: some View {
        OnboardingPage(
            id: "forgot.choose",
            lead: "Forgot a code?",
            title: "Reset it with your recovery sentence.",
            text: "Only if you turned this on for that space.",
            primary: "Use my sentence",
            primaryID: "forgot.words",
            action: { stage = .words },
            secondary: PageAction("Erase and start over", id: "forgot.erase") { erasing = true },
            onBack: { dismiss() },
            artHeight: 80
        ) {
            GlyphView(glyph: .key, lineWidth: 1.6).frame(width: 56, height: 56).foregroundStyle(Theme.gold)
        } content: {
            VStack(spacing: 12) {
                Button("Restore a space") {
                    guard let storage = app.storageForRecovery() else {
                        problem = "Unlock your iPhone and try again."
                        return
                    }
                    recovery = RecoveryRequest(storage: storage)
                }
                .buttonStyle(RaisedButtonStyle())
                .accessibilityIdentifier("forgot.restore")
                Text("Continue a restore with your sentence and the space's code.")
                    .font(.footnote).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                if let problem { Text(problem).font(.footnote) }
            }
        }
    }

    private var wordsStep: some View {
        OnboardingPage(
            id: "forgot.wordsStep",
            lead: "Your recovery sentence.",
            title: "Type it as you wrote it.",
            primary: "Next",
            primaryDisabled: RecoveryPhrase.tokens(phrase).isEmpty,
            primaryID: "forgot.next",
            action: checkWords,
            onBack: { stage = .choose }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PhraseField(text: $phrase, id: "forgot.phrase")
                    if let problem {
                        Text(problem).font(.footnote.weight(.semibold)).accessibilityIdentifier("forgot.problem")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var codeStep: some View {
        OnboardingPage(
            id: "forgot.codeStep",
            lead: first == nil ? "Your new code." : "Once more.",
            title: first == nil ? "Choose a code." : "Type it again.",
            onBack: { first = nil; stage = .words }
        ) {
            VStack(spacing: 14) {
                CodeInput(method: $method, text: $code, actionTitle: working ? "Resetting…" : (first == nil ? "Next" : "Reset code"),
                          minimumLength: method == .dots ? CodeRules.minimumDots : 6) { typed in
                    Task { await submit(typed) }
                }
                .disabled(working)
                if let problem {
                    Text(problem).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("forgot.problem")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var done: some View {
        OnboardingPage(id: "forgot.done", lead: "Code reset.", title: "Use it to open your space.",
                       primary: "Done", primaryID: "forgot.finish", action: { dismiss() }, artHeight: 110) {
            DrawnCheck(size: 88)
        } content: {
            EmptyView()
        }
    }

    private func checkWords() {
        do {
            try RecoveryKey.check(phrase)
            problem = nil
            stage = .code
        } catch {
            problem = phraseProblem(error)
            Haptics.play(.error)
        }
    }

    private func submit(_ typed: String) async {
        code = ""
        guard let chosen = first else {
            first = typed
            problem = nil
            Haptics.play(.soft)
            return
        }
        guard chosen == typed else {
            first = nil
            problem = "The codes didn't match. Start again."
            Haptics.play(.error)
            return
        }
        working = true
        defer { working = false }
        do {
            try await app.resetCode(phrase: phrase, newCode: typed)
            Haptics.play(.success)
            stage = .done
        } catch {
            first = nil
            problem = "This sentence can't reset a code here. It may be wrong, or the reset switch was off."
            Haptics.play(.error)
        }
    }
}
