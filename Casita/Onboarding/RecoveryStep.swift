import SwiftUI

/// Step 5: the recovery phrase, shown once. Backups and the reset switch are
/// asked later, inside a space, as closable notes above Lock.
struct RecoveryStep: View {
    let storage: ReservedStorage
    let top: SpaceRef
    var onDone: () -> Void

    @Environment(\.onboardingCompact) private var compact
    @State private var phrase = RecoveryPhrase()
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: compact ? 40 : 44)
            RecoveryKeyView(phrase: phrase) { await setKey() }
            if let error {
                Text(error)
                    .font(.footnote.weight(.semibold))
                    .padding()
                    .accessibilityIdentifier("onboarding.recovery.error")
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .tint(nil)
    }

    private func setKey() async {
        do {
            // The top space reaches every space, so every slot is sealed to
            // the new phrase. Stretching takes about a second, off the main thread.
            let key = await Task.detached(priority: .userInitiated) { [phrase] in RecoveryKey(phrase: phrase) }.value
            try await storage.setRecoveryKey(key, from: top)
            Haptics.play(.success)
            onDone()
        } catch {
            Haptics.play(.error)
            self.error = "The recovery key couldn't be saved. Try again."
        }
    }
}
