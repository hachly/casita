import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shows the recovery phrase once: one sentence, its random parts in white
/// and the joining words in grey, appearing part by part. People write it
/// down, copy it or take a screenshot; "I saved it" asks once more, because
/// Casita never shows it again.
struct RecoveryKeyView: View {
    let phrase: RecoveryPhrase
    /// Stretches and saves the key; the button says "Saving…" meanwhile.
    let onConfirmed: () async -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0
    @State private var copied = false
    @State private var toast: String?
    @State private var confirming = false
    @State private var saving = false

    private var partCount: Int { phrase.parts.count }
    private var allShown: Bool { shown >= partCount || reduceMotion }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    GlyphView(glyph: .key, lineWidth: 1.9)
                        .foregroundStyle(Theme.gold)
                        .frame(width: 30, height: 30)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Theme.surface))
                    TwoToneTitle(key: "Write down this sentence.", alignment: .center)
                    Text("Casita shows it only once.")
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    sentence
                        .padding(.top, 6)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 12)
                .column()
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 10) {
                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy sentence", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(RaisedButtonStyle())
                .accessibilityIdentifier("onboarding.recovery.copy")
                Button(saving ? "Saving…" : "I saved it") { confirming = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving)
                    .accessibilityIdentifier("onboarding.recovery.saved")
            }
            .padding(.horizontal, Theme.gutter)
            .column()
            .padding(.top, 8)
            .padding(.bottom, 12)
            .opacity(allShown ? 1 : 0)
            .offset(y: allShown ? 0 : 20)
            .animation(Theme.smooth, value: allShown)
            .allowsHitTesting(allShown)
        }
        .foregroundStyle(Theme.primary)
        .background(Theme.background)
        .toast($toast)
        .alert("Saved your sentence?", isPresented: $confirming) {
            Button("Not yet", role: .cancel) {}
            Button("I saved it") {
                saving = true
                Task {
                    await onConfirmed()
                    saving = false
                }
            }
        } message: {
            Text("Casita will never show it again. Without it, a forgotten code can't be reset and a backup can't be opened.")
        }
        // A screenshot is allowed, but it lands in Photos and iCloud Photos,
        // where anyone checking the iPhone looks first.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            Haptics.play(.warning)
            toast = "Saved to Photos. Keep it somewhere private."
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.recovery.words")
        .task { await reveal() }
    }

    /// One Text, so it wraps as a sentence; parts not yet shown are clear,
    /// so nothing moves as they arrive.
    private var sentence: some View {
        var part = 0
        var text = Text("")
        for (i, piece) in phrase.pieces.enumerated() {
            let on = !piece.isPart || part < shown || reduceMotion
            let word = Text((i == 0 ? "" : " ") + piece.text)
                .foregroundStyle(piece.isPart ? (on ? Theme.primary : .clear) : Theme.quiet)
            text = text + word
            if piece.isPart { part += 1 }
        }
        return (text + Text("."))
            .font(.title2.weight(.semibold))
            .lineSpacing(6)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.surface))
            .animation(.easeOut(duration: 0.25), value: shown)
            // No text selection: the system Copy reaches Universal Clipboard
            // and never expires; the Copy button stays on this iPhone for 2 minutes.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(phrase.sentence)
            .accessibilityIdentifier("onboarding.recovery.sentence")
    }

    /// The random parts arrive in reading order, a tick each, then a soft
    /// beat as the buttons arrive.
    private func reveal() async {
        guard !reduceMotion, shown < partCount else { return }
        try? await Task.sleep(for: .milliseconds(450))
        for i in 1...partCount {
            guard !Task.isCancelled else { return }
            shown = i
            Haptics.play(.tap)
            try? await Task.sleep(for: .milliseconds(160))
        }
        try? await Task.sleep(for: .milliseconds(180))
        Haptics.play(.soft)
    }

    private func copy() {
        // Local only and short-lived, so the sentence never reaches other
        // devices through Universal Clipboard or lingers in the pasteboard.
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: phrase.sentence]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)]
        )
        withAnimation(Theme.snappy) { copied = true }
        Haptics.play(.success)
        toast = "Copied. It clears in 2 minutes."
    }
}

extension UTType {
    static let casitaBackup = UTType(exportedAs: "com.hachly.casita.backup", conformingTo: .data)
}

/// A finished backup file, handed to `fileExporter`.
struct BackupExport: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        // fileExporter(item:) names the file from the Transferable, not its
        // defaultFilename, and throws on an empty name (iOS 26 and 27).
        FileRepresentation(exportedContentType: .casitaBackup) { SentTransferredFile($0.url) }
            .suggestedFileName("Casita")
    }
}

/// "Back up now": writes a backup to a temporary file and lets the user save
/// it anywhere through the system exporter. The temporary file is removed
/// when the exporter closes.
struct BackupExportButton: View {
    let storage: ReservedStorage
    var onExport: () -> Void = {}
    @State private var export: BackupExport?
    @State private var working = false
    @State private var failed = false
    @State private var failureMessage = ""
    @State private var staging: URL?

    var body: some View {
        Button(working ? "Preparing backup…" : "Back up now") {
            working = true
            Task {
                do {
                    let url = try MediaTemp.newFile(named: "Casita.\(BackupFile.fileExtension)")
                    staging = url
                    try await storage.writeBackup(to: url)
                    export = BackupExport(url: url)
                    Haptics.play(.success)
                } catch {
                    failureMessage = backupErrorMessage(error)
                    cleanUp()
                    failed = true
                    Haptics.play(.error)
                }
                working = false
            }
        }
        .disabled(working)
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
            item: export, contentTypes: [.casitaBackup], defaultFilename: "Casita"
        ) { result in
            switch result {
            case .success:
                var status = BackupStatus.current
                status.lastExport = .now
                BackupStatus.current = status
                onExport()
            case .failure(let error):
                failureMessage = backupErrorMessage(error)
                failed = true
            }
            cleanUp()
        } onCancellation: {
            cleanUp()
        }
        .alert("Backup couldn't be saved", isPresented: $failed) { Button("OK") {} } message: { Text(failureMessage) }
        // Writing a large backup, then choosing where to save it, takes no touches in Casita.
        .holdsIdleLock(working || export != nil)
    }

    private func cleanUp() {
        if let staging { MediaTemp.remove(staging) }
        staging = nil
        export = nil
    }
}
