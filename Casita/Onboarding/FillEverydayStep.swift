import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Step 6: the house takes in photos and a login; one switch says whether
/// to fill the everyday space now. On, it offers photos through the system
/// picker (no Photos permission), files, main accounts through Web, and
/// "Make more room" when the space runs low. Originals stay in Photos;
/// deleting them waits for a subscription.
struct FillEverydayStep: View {
    let storage: ReservedStorage
    let everyday: SpaceRef
    var onDone: () -> Void
    @Environment(Entitlements.self) private var entitlements
    @State private var showPaywall = false
    @State private var paywallReason: PlanLimit = .items

    @State private var picked: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var items: [MediaItem] = []
    @State private var importing = false
    @State private var showWeb = false
    @State private var free: Int64?
    @State private var growth: (from: StorageSize, to: StorageSize)?
    @State private var growing = false
    @State private var growProgress = 0.0
    @State private var error: String?
    @State private var fillNow = false
    @State private var choosingFiles = false
    @State private var filesAdded = 0

    var body: some View {
        OnboardingPage(
            id: "onboarding.fill",
            title: "Fill your everyday space.",
            text: "Normal photos and accounts make it look used.",
            primary: "Continue",
            primaryDisabled: importing || growing,
            action: onDone,
            artHeight: 280
        ) {
            HouseScene(story: .fill)
        } content: {
            // A short list sits in the middle; a long one scrolls.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }.scrollBounceBehavior(.basedOnSize)
            }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .task { await reload() }
        .paywall(isPresented: $showPaywall, reason: paywallReason)
        .photosPicker(isPresented: $showPicker, selection: $picked, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await importFiles(result) }
        }
        .onChange(of: picked) { _, new in
            guard !new.isEmpty else { return }
            Task { await importPicked(new) }
        }
        .sheet(isPresented: $showWeb) {
            NavigationStack {
                WebView(storage: storage, space: everyday)
                    .navigationTitle("Web")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showWeb = false } }
                    }
            }
            .preferredColorScheme(.dark)
            .tint(.white)
        }
        .alert("Make more room?", isPresented: Binding(get: { growth != nil }, set: { if !$0 { growth = nil } }), presenting: growth) { growth in
            Button("Make more room") { grow(growth.from, to: growth.to) }
            Button("Cancel", role: .cancel) {}
        } message: { growth in
            Text("Casita grows from \(StoragePlan.label(growth.from)) to \(StoragePlan.label(growth.to)). It takes \(StoragePlan.label(growth.from)) more from this iPhone. All new room goes to this space.")
        }
    }

    private var rows: some View {
        VStack(spacing: 10) {
            Card {
                Toggle(isOn: $fillNow.animation(Theme.smooth)) {
                    Text("Add things now").font(.body.weight(.semibold))
                }
                .toggleStyle(CasitaToggleStyle())
                .accessibilityIdentifier("onboarding.fill.toggle")
            }
            if fillNow { additions.transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }

    /// Photos, files and accounts side by side, so all three show under
    /// the house; each counts what went in.
    private var additions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { showPicker = true } label: {
                    tile(.photos, "Photos", items.isEmpty ? nil : "\(items.count) added", busy: importing)
                }
                .disabled(importing)
                .accessibilityIdentifier("onboarding.fill.photos")
                Button { choosingFiles = true } label: {
                    tile(.files, "Files", filesAdded == 0 ? nil : "\(filesAdded) added")
                }
                .disabled(importing)
                .accessibilityIdentifier("onboarding.fill.files")
                Button { showWeb = true } label: {
                    tile(.web, "Accounts", nil)
                }
                .accessibilityIdentifier("onboarding.fill.web")
            }
            // Settings › Storage always has it; here only when it is needed.
            if runsLow || growing {
                Button { askToGrow() } label: {
                    row(.spaces, "Make more room", roomDetail, busy: growing)
                }
                .disabled(growing)
                .accessibilityIdentifier("onboarding.fill.room")
                .transition(.opacity)
            }
            if growing {
                ProgressLine(value: growProgress)
                    .animation(.smooth(duration: 0.45), value: growProgress)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
            if let error {
                Text(error)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.fill.error")
            }
        }
        .animation(Theme.smooth, value: growing)
    }

    private func tile(_ glyph: Glyph, _ title: String, _ detail: String?, busy: Bool = false) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if busy { BusyDots() } else { GlyphView(glyph: glyph, lineWidth: 1.7).frame(width: 24, height: 24) }
            }
            .frame(height: 26)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail ?? " ").font(.caption).foregroundStyle(Theme.secondary).contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .foregroundStyle(Theme.primary)
    }

    private var runsLow: Bool { (free ?? .max) < StoragePlan.lowRoom }

    private var roomDetail: String {
        guard let free else { return "Grow Casita's storage for this space." }
        return "\(StoragePlan.label(bytes: free)) free in this space."
    }

    private func row(_ glyph: Glyph, _ title: String, _ detail: String?, busy: Bool = false) -> some View {
        HStack(spacing: 14) {
            GlyphView(glyph: glyph, lineWidth: 1.7)
                .frame(width: 22, height: 22)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.raised))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
            if busy {
                BusyDots()
            } else {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .foregroundStyle(Theme.primary)
    }

    private func reload() async {
        items = ((try? await storage.mediaItems(in: everyday)) ?? []).filter(\.kind.isGalleryItem)
        free = try? await storage.freeBytes(in: everyday)
    }

    private func importFiles(_ result: Result<[URL], any Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        importing = true
        error = nil
        defer { importing = false }
        var added = 0
        for url in urls {
            do {
                // The person's own file stays where it is; only a protected copy is taken in.
                try await MediaImport.importFile(at: try MediaTemp.copyIn(url), into: storage, space: everyday)
                added += 1
            } catch {
                if error is PlanLimit { paywallReason = .items; showPaywall = true; break }
                self.error = mediaErrorText(error)
                if (error as? StorageError) == .noRoom { break }
            }
        }
        filesAdded += added
        await reload()
        Haptics.play(error == nil ? .success : (added > 0 ? .warning : .error))
    }

    private func importPicked(_ new: [PhotosPickerItem]) async {
        importing = true
        error = nil
        defer { importing = false; picked = [] }
        var added = 0
        for pick in new {
            do {
                guard let file = try await pick.loadTransferable(type: PickedFile.self) else { continue }
                try await MediaImport.importFile(at: file.url, into: storage, space: everyday)
                added += 1
            } catch {
                if error is PlanLimit { paywallReason = .items; showPaywall = true; break }
                self.error = mediaErrorText(error)
            }
        }
        await reload()
        Haptics.play(error == nil ? .success : (added > 0 ? .warning : .error))
    }

    private func askToGrow() {
        guard entitlements.allows(.growStorage) else { paywallReason = .storage; showPaywall = true; return }
        error = nil
        Task {
            guard let current = StorageSize(rawValue: await storage.byteSize) else { return }
            if let next = StoragePlan.growth(from: current, available: StoragePlan.availableBytes()) {
                growth = (current, next)
            } else {
                Haptics.play(.warning)
                error = current.next == nil
                    ? "Casita's storage is already at its largest size."
                    : "There isn't enough free space on this iPhone to make more room."
            }
        }
    }

    private func grow(_ from: StorageSize, to target: StorageSize) {
        growing = true
        growProgress = 0
        let span = Double(target.rawValue - from.rawValue)
        let poll = Task {
            while !Task.isCancelled {
                let attributes = try? FileManager.default.attributesOfItem(atPath: AppModel.storageURL.path)
                if let bytes = (attributes?[.size] as? NSNumber)?.doubleValue {
                    growProgress = max(growProgress, min(1, (bytes - Double(from.rawValue)) / span))
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        Task {
            defer { poll.cancel(); growing = false }
            do {
                try await storage.grow(for: everyday)
                await reload()
                Haptics.play(.success)
            } catch {
                self.error = "Casita couldn't make more room. Free up space on this iPhone and try again."
                Haptics.play(.error)
            }
        }
    }
}
