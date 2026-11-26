import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Save to Casita. Shows the same entry screen as the app, then streams the
/// shared items into whichever space the code opened.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.items = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        model.finish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareRootView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.start()
    }
}

@MainActor @Observable
final class ShareModel: EntryController {
    enum Phase { case locked, saving(done: Int, total: Int), saved(Int), failed(String), noStorage }

    var phase: Phase = .locked
    private(set) var checking = false
    let waits = WrongCodeWaits()
    var hideDotsLine: Bool { LockSettingsStore.standard.load().hideDotsLine }
    var haptics: Bool { LockSettingsStore.standard.load().haptics }
    var items: [NSItemProvider] = []
    var finish: () -> Void = {}
    var cancel: () -> Void = {}
    private var storage: ReservedStorage?

    /// Plain copies of shared items live here only while they are saved. A
    /// save the memory limit or a swipe cut short leaves them behind, so
    /// every start clears the folder.
    nonisolated static let copies = FileManager.default.temporaryDirectory.appendingPathComponent("casita-share", isDirectory: true)

    func start() {
        try? FileManager.default.removeItem(at: Self.copies)
        if AppGroup.spaceOpenInApp {
            phase = .failed("Casita has a space open. Lock it, then share again.")
            return
        }
        storage = try? ReservedStorage.open(at: AppGroup.storageURL, stretcher: .default, access: .purchases)
        if storage == nil { phase = .noStorage }
    }

    func submit(code: String) async -> Bool {
        guard let storage, !checking, !waits.isWaiting else { return false }
        checking = true
        defer { checking = false }
        guard let ref = (try? await storage.unlock(code: code)) ?? nil else {
            waits.registerWrongAttempt()
            return false
        }
        await save(into: ref, storage: storage)
        return true
    }

    func unlockWithFaceID() async -> FaceIDResult {
        guard let storage, let credential = try? await EverydayCredentialStore.load(),
              let ref = try? await storage.open(credential) else { return .failed }
        await save(into: ref, storage: storage)
        return .opened
    }

    private func save(into ref: SpaceRef, storage: ReservedStorage) async {
        let total = items.count
        var done = 0
        phase = .saving(done: 0, total: total)
        for item in items {
            do {
                let (url, name) = try await item.temporaryFile()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                try await storage.addUserFile(named: name, from: url, in: ref)
                done += 1
                phase = .saving(done: done, total: total)
            } catch {
                await storage.lockAll()
                phase = .failed(error is PlanLimit ? "This space has 50 items. Open Casita to upgrade or remove an item." : (error is StorageError ? "Not enough room in this space." : "Couldn't read that item."))
                return
            }
        }
        await storage.lockAll()
        phase = .saved(done)
    }
}

extension NSItemProvider: @unchecked @retroactive Sendable {}

private extension NSItemProvider {
    /// Writes the item to a temporary file (NSItemProvider's own copy is only
    /// valid inside the callback) and returns it with a usable file name.
    nonisolated func temporaryFile() async throws -> (URL, String) {
        let type = [UTType.movie, .image, .pdf, .data].first { hasItemConformingToTypeIdentifier($0.identifier) } ?? .data
        return try await withCheckedThrowingContinuation { continuation in
            _ = loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile)) }
                let folder = ShareModel.copies.appendingPathComponent(UUID().uuidString, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                            attributes: [.protectionKey: FileProtectionType.complete])
                    let copy = folder.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: (copy, url.lastPathComponent))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct ShareRootView: View {
    let model: ShareModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.phase {
            case .locked:
                EntryView(model: model)
                    .overlay(alignment: .topTrailing) {
                        Button("Cancel") { model.cancel() }
                            .font(.body.weight(.medium))
                            .foregroundStyle(Theme.secondary)
                            .padding(Theme.gutter)
                            .accessibilityIdentifier("share.cancel")
                    }
            case .saving(let done, let total):
                ShareStatus(text: "Saving \(done) of \(total)…", progress: total > 0 ? Double(done) / Double(total) : 0)
            case .saved(let count):
                ShareStatus(text: count == 1 ? "Saved to this space" : "Saved \(count) items to this space", done: true, button: "Done", action: model.finish)
            case .failed(let message):
                ShareStatus(text: message, button: "Close", action: model.finish)
            case .noStorage:
                ShareStatus(text: "Open Casita once to set it up first.", button: "Close", action: model.finish)
            }
        }
        .foregroundStyle(Theme.primary)
        .preferredColorScheme(.dark)
    }
}

/// Saving, saved or why not: the logo (or a check once saved), one line,
/// and the way out.
private struct ShareStatus: View {
    var text: String
    var progress: Double?
    var done = false
    var button: String?
    var action: () -> Void = {}
    @State private var landed = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                if done {
                    Circle().fill(.white).frame(width: 72, height: 72)
                        .overlay(Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(.black))
                        .scaleEffect(landed ? 1 : 0.4)
                        .opacity(landed ? 1 : 0)
                } else {
                    CasitaMark(style: .onDark).frame(width: 64, height: 64)
                }
            }
            .frame(height: 80)
            Text(text).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            if let progress {
                ProgressView(value: progress).tint(.white).frame(maxWidth: 220)
                    .animation(Theme.smooth, value: progress)
            }
            Spacer()
            if let button {
                Button(button, action: action).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("share.done")
            }
        }
        .padding(Theme.gutter)
        .column()
        .onAppear {
            guard done else { return }
            Haptics.play(.success)
            withAnimation(Theme.bouncy) { landed = true }
        }
    }
}
