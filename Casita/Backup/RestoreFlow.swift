import SwiftUI
import UniformTypeIdentifiers

/// "Restore from a backup" on a phone with no Casita storage yet: choose the
/// backup file, type the recovery sentence, then the code of each space to
/// bring back. Spaces come back one code at a time, so nothing here lists or
/// counts the spaces in the backup.
struct RestoreFlow: View {
    var onCancel: () -> Void
    var existingStorage: ReservedStorage? = nil

    @Environment(AppModel.self) private var app
    @State private var stage: Stage = .file
    @State private var backup: URL?
    @State private var phrase = ""
    @State private var key: RecoveryKey?
    @State private var storage: ReservedStorage?
    @State private var choosing = false
    @State private var problem: String?
    @State private var brought = false
    @State private var method = EntryView.Method.numbers
    @State private var code = ""
    @State private var checking = false
    @State private var toast: String?
    @State private var finished = false

    enum Stage { case file, words, restoring, codes }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch stage {
            case .file: fileStep
            case .words: wordsStep
            case .restoring: restoringStep
            case .codes: codesStep
            }
        }
        .foregroundStyle(Theme.primary)
        .animation(Theme.smooth, value: stage)
        .toast($toast)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.casitaBackup, .data]) { result in
            switch result {
            case .success(let url):
                backup = url
                problem = nil
                Haptics.play(.select)
                stage = .words
            case .failure(let error):
                problem = backupErrorMessage(error)
            }
        }
        .interactiveDismissDisabled(checking || stage == .restoring)
        .task {
            if let existingStorage, storage == nil {
                storage = existingStorage
                stage = .words
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Steps

    private var fileStep: some View {
        OnboardingPage(
            id: "restore.file",
            lead: "Restore.",
            title: "Choose your backup.",
            text: "Choose it in iCloud Drive › Casita, or wherever you saved it.",
            primary: "Choose backup",
            primaryID: "restore.choose",
            action: {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-devBackupFile") {
                    backup = AppModel.devBackupURL
                    stage = .words
                    return
                }
                #endif
                choosing = true
            },
            secondary: PageAction("Cancel", id: "restore.cancel", action: onCancel),
            artHeight: 80
        ) {
            GlyphView(glyph: .cloud, lineWidth: 1.6).frame(width: 56, height: 56).foregroundStyle(Theme.gold)
        } content: {
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private var wordsStep: some View {
        OnboardingPage(
            id: "restore.words",
            lead: "Your recovery sentence.",
            title: "Type it as you wrote it.",
            primary: "Restore",
            primaryDisabled: RecoveryPhrase.tokens(phrase).isEmpty,
            primaryID: "restore.go",
            action: startRestore,
            secondary: PageAction("Paste sentence", id: "restore.paste", action: paste),
            onBack: { if storage != nil { finish() } else { stage = .file } }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PhraseField(text: $phrase, id: "restore.phrase")
                    if let problem {
                        Text(problem).font(.footnote.weight(.semibold)).foregroundStyle(Theme.primary)
                            .accessibilityIdentifier("restore.problem")
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var restoringStep: some View {
        OnboardingPage(id: "restore.working", lead: "Restoring.", title: "Keep Casita open.") {
            VStack {
                Spacer()
                ProgressView().controlSize(.large).tint(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var codesStep: some View {
        OnboardingPage(
            id: "restore.codes",
            lead: brought ? "Space restored." : "Restore a space.",
            title: brought ? "Another code, or Done." : "Type each space's code.",
            primary: brought ? "Done" : nil,
            primaryDisabled: checking,
            primaryID: "restore.done",
            action: finish,
            secondary: PageAction("Use another sentence", id: "restore.otherSentence") {
                guard !checking else { return }
                key = nil
                phrase = ""
                problem = nil
                stage = .words
            },
            onBack: { if !checking { finish() } }
        ) {
            VStack(spacing: 14) {
                CodeInput(method: $method, text: $code, actionTitle: checking ? "Checking…" : "Bring it back", minimumLength: 1) { typed in
                    Task { await adopt(typed) }
                }
                .disabled(checking)
                if let problem {
                    Text(problem).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("restore.problem")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Actions

    private func paste() {
        guard let pasted = UIPasteboard.general.string, !RecoveryPhrase.tokens(pasted).isEmpty else {
            problem = "Nothing to paste."
            Haptics.play(.warning)
            return
        }
        phrase = pasted
        problem = nil
        Haptics.play(.success)
    }

    private func startRestore() {
        guard storage != nil || backup != nil else { stage = .file; return }
        do {
            try RecoveryKey.check(phrase)
        } catch {
            problem = phraseProblem(error)
            Haptics.play(.error)
            return
        }
        problem = nil
        stage = .restoring
        Task {
            do {
                let parsed = try await RecoveryKey.typed(phrase)
                key = parsed
                if storage == nil, let backup {
                    storage = try await app.restore(backup: backup, key: parsed)
                }
                Haptics.play(.unlock)
                stage = .codes
            } catch BackupError.wrongRecoveryKey {
                problem = "This sentence doesn't open this backup."
                Haptics.play(.error)
                stage = .words
            } catch BackupError.notBackupFile {
                problem = "That file isn't a Casita backup."
                Haptics.play(.error)
                stage = .file
            } catch {
                problem = backupErrorMessage(error)
                Haptics.play(.error)
                stage = storage == nil ? .file : .words
            }
        }
    }

    private func adopt(_ typed: String) async {
        guard let storage, let key, !checking, !finished else { return }
        // The entry screen's rules: no code works during a wait, a miss counts
        // as a wrong try, and every try takes the same time.
        if let until = app.waits.waitUntil {
            code = ""
            problem = "Too many wrong codes. Try again in \(EntryView.countdown(max(1, Int(until.timeIntervalSinceNow.rounded(.up)))))."
            Haptics.play(.error)
            return
        }
        checking = true
        defer { checking = false; code = "" }
        let clock = ContinuousClock()
        let deadline = clock.now + (await storage.minimumUnlockDuration)
        do {
            let ref = try await storage.adopt(code: typed, recoveryKey: key)
            try? await Task.sleep(until: deadline, clock: clock)
            guard ref != nil else {
                app.waits.registerWrongAttempt()
                problem = "This sentence and code don't open a space."
                Haptics.play(.error)
                return
            }
            // Adoption only registers this phone's code. It need not leave
            // any decrypted space open behind the recovery screen.
            await storage.lockAll()
            brought = true
            problem = nil
            toast = "Space restored"
            Haptics.play(.success)
        } catch {
            problem = (error as? StorageError) == .codeInUse
                ? "That code is already used here. Change the other space's code, then try again."
                : backupErrorMessage(error)
            Haptics.play(.error)
        }
    }

    private func finish() {
        guard !checking, !finished else { return }
        finished = true
        checking = true
        key = nil
        phrase = ""
        Task {
            await storage?.lockAll()
            app.finishFirstRun()
            onCancel()
        }
    }
}

/// Where the recovery sentence is typed back, as it was written down. A key
/// from before phrases, 12 words, can be typed here too.
struct PhraseField: View {
    @Binding var text: String
    let id: String

    var body: some View {
        TextField("Type your sentence", text: $text, axis: .vertical)
            .lineLimit(3...6)
            .font(.title3.weight(.semibold))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
            .accessibilityIdentifier(id)
    }
}

/// Plain words for a sentence that doesn't read.
func phraseProblem(_ error: any Error) -> String {
    switch error as? RecoveryKeyError {
    case .unknownWord(let word): "“\(word)” isn't a word Casita uses. Check the spelling."
    case .badChecksum: "Check each word."
    default: "Check the sentence is complete."
    }
}
