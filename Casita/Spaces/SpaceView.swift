import StoreKit
import SwiftUI

/// A space's main screen: Casita's own features as big flat tiles with
/// Casita's glyphs, and Lock at the bottom. It never shows the space's
/// name, and it is not a home screen: no wallpaper, dock, page dots or
/// app icons, just the six things a space holds.
struct SpaceView: View {
    let space: SpaceRef
    @Environment(AppModel.self) private var model
    @Environment(Entitlements.self) private var entitlements
    @State private var showPaywall = false
    @State private var paywallReason: PlanLimit = .automaticBackup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.requestReview) private var requestReview
    @Namespace private var zoom
    @State private var appeared = false
    @State private var path: [Feature] = []
    /// The short message of whichever screen is on the stack, shown over the bar.
    @State private var toasts = ToastCenter()
    /// A failed automatic backup, told once in whichever space opens next.
    @State private var backupNote: String?
    /// "Open Casita in one press": app-wide, the same in every space, until
    /// it is closed or opened.
    @State private var showsTip = !AppGroup.defaults.bool(forKey: SpaceView.tipClosedKey)
    @State private var showsGuide = false
    /// Under `StoragePlan.lowRoom` free; closing it hides it until the next opening.
    @State private var lowRoom = false
    @State private var lowRoomClosed = false
    /// Items in this space once it nears the free allowance; closing the
    /// note hides it until the next opening.
    @State private var freeUsed: Int?
    @State private var freeClosed = false
    /// "Back up to iCloud?": app-wide, until a schedule is chosen.
    @State private var askBackup = false
    /// "Let your sentence reset this code?": this space's own question,
    /// remembered inside the space, so nothing outside it shows the answer.
    @State private var askReset = false
    @State private var confirmBackup = false
    @State private var confirmReset = false
    @State private var reservedBytes: Int64?

    static let tipClosedKey = "tip.openFaster.closed"
    /// Written into the space once its reset question is answered.
    static let resetAskedFile = "app/asked-reset"

    /// The one note above Lock, most pressing first.
    private enum Note: Hashable { case backupFailed(String), lowRoom, freeRoom(String), askBackup, askReset, tip }

    private var note: Note? {
        if let backupNote { return .backupFailed(backupNote) }
        if lowRoom { return .lowRoom }
        if !freeClosed, !entitlements.isSubscribed, let text = freeUsed.flatMap(FreePlan.headsUp) { return .freeRoom(text) }
        if askBackup { return .askBackup }
        if askReset { return .askReset }
        return showsTip ? .tip : nil
    }

    enum Feature: String, CaseIterable, Hashable {
        case photos, camera, files, web, spaces, settings

        var title: String {
            switch self {
            case .photos: "Photos"
            case .camera: "Camera"
            case .files: "Files"
            case .web: "Web"
            case .spaces: "Spaces"
            case .settings: "Settings"
            }
        }

        var glyph: Glyph {
            switch self {
            case .photos: .photos
            case .camera: .camera
            case .files: .files
            case .web: .web
            case .spaces: .spaces
            case .settings: .settings
            }
        }
    }

    private static let tileSpacing: CGFloat = 14
    /// Width over height of a tile.
    private static let tileAspect: CGFloat = 1.2

    /// Reduce Motion shows everything in place from the start.
    private var shown: Bool { appeared || reduceMotion }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                CasitaMark()
                    .frame(width: 30, height: 30)
                    .padding(.top, 12)
                    .reveal(0, active: shown)
                    .accessibilityHidden(true)
                GeometryReader { room in
                    tiles(in: room.size)
                        .frame(width: room.size.width, height: room.size.height)
                }
                .padding(.vertical, 20)
                // A note's place is kept while there is none, so the tiles
                // never move as notes come and go.
                ZStack {
                    NoteRow(note: " ", onOpen: {}, onClose: {})
                        .hidden()
                        .accessibilityHidden(true)
                    if let note {
                        noteRow(note)
                            .id(note)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .reveal(Feature.allCases.count + 1, active: shown)
                    }
                }
                .padding(.bottom, 14)
                .column()
                Button {
                    Haptics.play(.thud)
                    model.lock()
                } label: {
                    HStack(spacing: 10) {
                        GlyphView(glyph: .lock, lineWidth: 2)
                            .frame(width: 20, height: 20)
                            .foregroundStyle(Theme.gold)
                        Text("Lock").font(.headline)
                    }
                    .padding(.horizontal, 28)
                    .frame(height: 54)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .reveal(Feature.allCases.count + 1, active: shown)
                .accessibilityIdentifier("space.lock")
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .foregroundStyle(Theme.primary)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Feature.self) { feature in
                destination(feature)
                    .navigationTransition(.zoom(sourceID: feature, in: zoom))
            }
            // Back home from a feature: what was added may have filled the space.
            .task(id: path.isEmpty) {
                guard path.isEmpty else { return }
                await refreshNotes()
                // After real use only, on the space's own screen, once.
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled, path.isEmpty, RatingPrompt.takeTurn() { requestReview() }
            }
            .sheet(isPresented: $showsGuide) {
                NavigationStack { OpenFasterGuide() }
                    .presentationBackground(Theme.background)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("space.screen")
        .paywall(isPresented: $showPaywall, reason: paywallReason)
            // Where this space is, for reopening there after a short lock.
            .onChange(of: path) { _, path in
                model.place.feature = path.last?.rawValue
                if path.last != .web { model.place.webURL = nil }
            }
            .onChange(of: model.resumeTo, initial: true) { _, place in
                guard let raw = place?.feature, let feature = Feature(rawValue: raw) else { return }
                path = [feature]
                // Web takes the page from it; nothing else needs it.
                if feature != .web || place?.webURL == nil { model.resumeTo = nil }
            }
            .onAppear {
                // Once per opening; coming back from a feature is quiet.
                guard !appeared else { return }
                appeared = true
                Haptics.play(.unlock)
                if let note = BackupStatus.takeNote() {
                    withAnimation(Theme.smooth.delay(0.6)) { backupNote = note }
                }
            }
        }
        // Short messages from the screens on the stack show over the bar.
        .environment(\.toastCenter, toasts)
        .toast(Bindable(toasts).message)
        .tint(.white)
    }

    /// Two columns of three on a phone. A wide screen (an open iPhone Duo)
    /// gets three columns of two. Either way the tiles keep their shape and
    /// grow only as far as the room between the logo and the note allows.
    private func tiles(in room: CGSize) -> some View {
        let spacing = Self.tileSpacing
        let columns = room.width > room.height * 1.4 ? 3 : 2
        let rows = (Feature.allCases.count + columns - 1) / columns
        let across = (room.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let down = (room.height - spacing * CGFloat(rows - 1)) / CGFloat(rows) * Self.tileAspect
        let side = max(0, min(across, down))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columns), spacing: spacing) {
            ForEach(Array(Feature.allCases.enumerated()), id: \.element) { index, feature in
                NavigationLink(value: feature) {
                    FeatureTile(feature: feature)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.96))
                .matchedTransitionSource(id: feature, in: zoom) { source in
                    source
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
                }
                .reveal(index + 1, active: shown)
                .accessibilityIdentifier("space.tile.\(feature.rawValue)")
            }
        }
    }

    @ViewBuilder private func noteRow(_ note: Note) -> some View {
        switch note {
        case .backupFailed(let text):
            NoteRow(note: text) {
                withAnimation(Theme.snappy) { backupNote = nil }
                path.append(.settings)
            } onClose: {
                withAnimation(Theme.snappy) { backupNote = nil }
            }
        case .lowRoom:
            NoteRow(glyph: .house, note: "This space is almost full", id: "space.lowRoom") {
                path.append(.settings)
            } onClose: {
                lowRoomClosed = true
                withAnimation(Theme.snappy) { lowRoom = false }
            }
        case .freeRoom(let text):
            NoteRow(glyph: .photos, note: text, id: "space.freeRoom") {
                paywallReason = .items
                showPaywall = true
            } onClose: {
                freeClosed = true
                withAnimation(Theme.snappy) { freeUsed = nil }
            }
        case .askBackup:
            NoteRow(glyph: .cloud, note: "Back up to iCloud?", id: "space.askBackup") {
                if entitlements.allows(.automaticBackup) { confirmBackup = true } else { paywallReason = .automaticBackup; showPaywall = true }
            } onClose: {
                BackupStatus.schedule = .off
                withAnimation(Theme.snappy) { askBackup = false }
            }
            .alert("Back up to iCloud weekly?", isPresented: $confirmBackup) {
                Button("Back up") {
                    BackupStatus.schedule = .weekly
                    BackupScheduler.shared.schedule()
                    withAnimation(Theme.snappy) { askBackup = false }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text(backupMessage)
            }
        case .askReset:
            NoteRow(glyph: .key, note: "Let your sentence reset this code?", id: "space.askReset") {
                confirmReset = true
            } onClose: {
                Task { await answerReset(on: false) }
            }
            .alert("Let your sentence reset this code?", isPresented: $confirmReset) {
                Button("Turn on") { Task { await answerReset(on: true) } }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("If you forget this code, your recovery sentence can set a new one. Anyone with your sentence could then open this space.")
            }
        case .tip:
            NoteRow(symbol: "bolt", note: "Open Casita in one press", id: "space.tip") {
                closeTip()
                showsGuide = true
            } onClose: {
                closeTip()
            }
        }
    }

    private var backupMessage: String {
        let size = reservedBytes.map { StoragePlan.label(bytes: $0) } ?? "Casita's storage"
        return "On Wi-Fi while charging. Each copy uses about \(size) of iCloud; two copies may be kept until uploading finishes. Only your recovery sentence opens it."
    }

    private func refreshNotes() async {
        guard let storage = model.storage else { return }
        let free = try? await storage.freeBytes(in: space)
        let used = try? await storage.userItemCount(in: space)
        let resetOn = (try? await storage.resetsWithRecoveryKey(space)) ?? false
        let asked = (try? await storage.readFile(named: Self.resetAskedFile, in: space)) != nil
        reservedBytes = await storage.byteSize
        withAnimation(Theme.snappy) {
            lowRoom = !lowRoomClosed && (free ?? .max) < StoragePlan.lowRoom
            freeUsed = freeClosed ? nil : used
            askBackup = BackupStatus.notAskedYet
            askReset = !resetOn && !asked
        }
    }

    /// Either answer is remembered inside this space; "Turn on" also sets
    /// this space's reset switch.
    private func answerReset(on: Bool) async {
        guard let storage = model.storage else { return }
        if on { try? await storage.setResetWithRecoveryKey(true, for: space) }
        try? await storage.writeFile(named: Self.resetAskedFile, data: Data([1]), in: space)
        if on { Haptics.play(.success) }
        withAnimation(Theme.snappy) { askReset = false }
    }

    private func closeTip() {
        AppGroup.defaults.set(true, forKey: Self.tipClosedKey)
        withAnimation(Theme.snappy) { showsTip = false }
    }

    @ViewBuilder private func destination(_ feature: Feature) -> some View {
        if let storage = model.storage {
            switch feature {
            case .photos: MediaGalleryView(storage: storage, space: space)
            case .camera: CameraView(storage: storage, space: space)
            case .files: FilesView(storage: storage, space: space)
            case .web: WebView(storage: storage, space: space)
            case .spaces: SpacesListView(parent: space)
            case .settings: SettingsView(space: space)
            }
        }
    }
}

/// A one-line note above Lock with a close button: "The last backup didn't
/// finish. See Settings." or the Open-faster tip. Tapping it opens more.
private struct NoteRow: View {
    var symbol: String?
    var glyph: Glyph = .cloud
    var note: String
    var id = "space.backupNote"
    var onOpen: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Group {
                        if let symbol { Image(systemName: symbol).font(.body.weight(.semibold)) } else { GlyphView(glyph: glyph, lineWidth: 1.8) }
                    }
                    .frame(width: 20, height: 20)
                    Text(note)
                        .font(.footnote.weight(.medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98))
            .accessibilityIdentifier(id)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.raised))
            }
            .buttonStyle(PressableButtonStyle(scale: 0.88))
            .accessibilityLabel("Close")
            .accessibilityIdentifier("\(id).close")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
    }
}

/// One feature: a flat grey tile, the glyph at the top, the name under it.
struct FeatureTile: View {
    let feature: SpaceView.Feature

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlyphView(glyph: feature.glyph, lineWidth: 1.6)
                .frame(width: 34, height: 34)
            Spacer(minLength: 12)
            Text(feature.title)
                .font(.title3.weight(.semibold))
                .tracking(-0.3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aspectRatio(1.2, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous).strokeBorder(Theme.hairline))
        .contentShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(feature.title)
    }
}
