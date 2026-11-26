import PhotosUI
import SwiftUI
import UIKit

/// The photos and videos of one space: the library, an edge-to-edge grid
/// sorted and filtered as chosen, or the albums.
struct MediaGalleryView: View {
    let storage: ReservedStorage
    let space: SpaceRef

    @Environment(Entitlements.self) private var entitlements
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoom
    @State private var items: [MediaItem] = []
    /// Photos, videos and files in this space, shown against the free allowance.
    @State private var freeUsed: Int?
    @State private var loaded = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showPaywall = false
    @State private var paywallReason: PlanLimit = .items
    private struct ScanRequest: Equatable {
        var items: [MediaItem]?
        var hasPlan: Bool
    }
    @State private var selected: MediaItem?
    @State private var showCamera = false
    @State private var progress: ImportProgress?
    @State private var afterImport: AfterImport?
    /// Shown once the error alert closes, so two alerts never collide.
    @State private var askAfterError: [String]?
    @State private var error: String?
    @State private var toast: String?
    @State private var tab = Tab.library
    /// How the library is shown: the same in every space.
    @AppStorage("photos.newestFirst") private var newestFirst = true
    @AppStorage("photos.show") private var show = Show.all
    @State private var albums = Albums()
    @State private var openAlbum: AlbumRoute?
    @State private var addingToAlbum: MediaItem?
    @State private var namingAlbum = false
    @State private var albumName = ""
    /// What Casita worked out about each photo, for the automatic albums.
    @State private var facts = PhotoFacts()
    @State private var factsLoaded = false
    @State private var added: [String: Date] = [:]
    @State private var sorting: (done: Int, total: Int)?

    enum Tab: String { case library, albums }

    enum Show: String, CaseIterable {
        case all, photos, videos
        var label: String {
            switch self {
            case .all: "Everything"
            case .photos: "Photos"
            case .videos: "Videos"
            }
        }
    }

    /// The library as chosen: what kind, and which way round.
    private var shownItems: [MediaItem] {
        let kept = items.filter {
            switch show {
            case .all: true
            case .photos: $0.kind == .image
            case .videos: $0.kind == .video
            }
        }
        return newestFirst ? kept : kept.reversed()
    }

    /// Three across on a phone, more on a wide screen (an open iPhone Duo).
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 2)]

    private enum AfterImport {
        case askDelete([String]), deleted, denied

        var title: String {
            switch self {
            case .askDelete: "Delete the originals from Photos?"
            case .deleted: "Originals deleted"
            case .denied: "Delete them by hand"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    ScreenHeader(title: "Photos", detail: countLine)
                    if !entitlements.isSubscribed, let freeUsed, freeUsed > 0 {
                        FreeCountLine(used: freeUsed) { paywallReason = .items; showPaywall = true }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                if let progress {
                    ImportProgressBar(progress: progress)
                        .padding(.horizontal, Theme.gutter)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if tab == .albums {
                    if !entitlements.isSubscribed {
                        Button {
                            paywallReason = .smartAlbums
                            showPaywall = true
                        } label: {
                            CasitaRow(glyph: .photos, title: "Let Casita sort your photos", detail: "People, places, things and dates · Premium")
                        }
                        .buttonStyle(RowPressStyle())
                        .padding(.horizontal, Theme.gutter)
                        .accessibilityIdentifier("albums.upgrade")
                    }
                    AlbumsGrid(storage: storage, space: space, albums: albums, smart: smart, sorting: sorting,
                               onOpen: { openAlbum = $0 }, onNew: { albumName = ""; namingAlbum = true })
                } else {
                    if loaded, items.isEmpty, progress == nil {
                        empty
                            .padding(.top, 72)
                            .transition(.opacity)
                    }
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(shownItems.enumerated()), id: \.element.id) { index, item in
                            Button { open(item) } label: {
                                ThumbnailCell(storage: storage, space: space, item: item)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .buttonStyle(PressableButtonStyle(scale: 0.96))
                            .matchedTransitionSource(id: item.id, in: zoom)
                            .contextMenu {
                                Button { addingToAlbum = item } label: { Label("Add to album", systemImage: "rectangle.stack.badge.plus") }
                            }
                            .transition(reduceMotion ? AnyTransition.opacity : .scale(scale: 0.6).combined(with: .opacity))
                            .accessibilityLabel(item.kind == .video ? "Video" : "Photo")
                            .accessibilityIdentifier("photos.cell.\(index)")
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        // Library and Albums sit bottom left, as in Apple's Photos; the grid
        // scrolls under them.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                PhotosTabs(selection: $tab)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photos.screen")
        .holdsIdleLock(showPicker || progress != nil)
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
        .foregroundStyle(Theme.primary)
        .preferredColorScheme(.dark)
        .collapsingTitle("Photos", readable: false)
        .toolbar {
            if tab == .library, !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Order", selection: $newestFirst) {
                            Text("Newest first").tag(true)
                            Text("Oldest first").tag(false)
                        }
                        Picker("Show", selection: $show) {
                            ForEach(Show.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                    } label: { CircleIcon(symbol: "arrow.up.arrow.down") }
                    .accessibilityLabel("Sort and show")
                    .accessibilityIdentifier("photos.sort")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openCamera) {
                    GlyphView(glyph: .camera, lineWidth: 2).frame(width: 18, height: 18)
                }
                .buttonStyle(CircleButtonStyle(size: 38))
                .accessibilityLabel("Camera")
                .accessibilityIdentifier("photos.camera")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: add) { Image(systemName: "plus") }
                    .buttonStyle(CircleButtonStyle(size: 38, fill: Theme.primary, tint: .black))
                    .accessibilityLabel("Add photos")
                    .accessibilityIdentifier("photos.add")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .barToast($toast)
        .paywall(isPresented: $showPaywall, reason: paywallReason)
        .photosPicker(isPresented: $showPicker, selection: $picked, matching: .any(of: [.images, .videos]), photoLibrary: .shared())
        .onChange(of: picked) { _, new in
            guard !new.isEmpty else { return }
            Task { await importPicked(new) }
        }
        .navigationDestination(item: $openAlbum) { route in
            AlbumView(storage: storage, space: space, route: route, smart: smart, albums: $albums, facts: $facts,
                      onChange: { Task { await saveAlbums() } }, onFactsChange: { Task { await saveFacts() } },
                      onLibraryChange: { Task { await reload(animated: true) } })
        }
        .sheet(item: $addingToAlbum) { item in
            AlbumPicker(albums: $albums, item: item) { name in
                Task { await saveAlbums() }
                toast = "Added to \(name)"
            }
        }
        .alert("New album", isPresented: $namingAlbum) {
            TextField("Name", text: $albumName)
                .autocorrectionDisabled()
            Button("Create") {
                let album = albums.create(albumName)
                Task { await saveAlbums() }
                openAlbum = .album(album.id)
            }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(item: $selected) { item in
            MediaViewerView(storage: storage, space: space, item: item) { Task { await reload(animated: true) } }
                .navigationTransition(.zoom(sourceID: item.id, in: zoom))
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: { Task { await reload(animated: true) } }) {
            CameraView(storage: storage, space: space)
        }
        .alert(afterImport?.title ?? "", isPresented: Binding(get: { afterImport != nil }, set: { if !$0 { afterImport = nil } }), presenting: afterImport) { step in
            if case .askDelete(let ids) = step {
                Button("Delete originals", role: .destructive) { Task { await deleteOriginals(ids) } }
                Button("Keep them", role: .cancel) {}
            } else {
                Button("OK") {}
            }
        } message: { step in
            switch step {
            case .askDelete: Text("They are safe in this space now. Casita will ask for Photos access to delete them.")
            case .deleted: Text(DeleteOriginals.recentlyDeletedReminder)
            case .denied: Text(DeleteOriginals.manualSteps)
            }
        }
        .alert("Couldn't add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {
                if let ids = askAfterError {
                    askAfterError = nil
                    afterImport = .askDelete(ids)
                }
            }
        } message: { Text(error ?? "") }
        .task { await reload(animated: false) }
        // Looks at new photos while Photos is open; a change to the library
        // starts it again from where it was.
        .task(id: ScanRequest(items: loaded ? items : nil, hasPlan: entitlements.isSubscribed)) { if loaded { await sort() } }
    }

    private var smart: SmartAlbums { SmartAlbums(library: items, facts: facts, added: added, allowsNewTimeline: entitlements.isSubscribed) }

    private var empty: some View {
        EmptyStateView(glyph: .photos, line: "Photos and videos you add here stay in this space.") {
            Button("Add photos", action: add)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("photos.empty.add")
            Button("Take a photo", action: openCamera)
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("photos.empty.camera")
        }
        .padding(.horizontal, Theme.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("photos.empty")
    }

    private var countLine: String? {
        guard !items.isEmpty else { return nil }
        let videos = items.filter { $0.kind == .video }.count
        let photos = items.count - videos
        return [photos > 0 ? counted(photos, "photo", "photos") : nil, videos > 0 ? counted(videos, "video", "videos") : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: Actions

    private func add() {
        Task {
            do { try await storage.checkCanAddItem(in: space); showPicker = true }
            catch is PlanLimit { paywallReason = .items; showPaywall = true }
            catch { self.error = mediaErrorText(error) }
        }
    }

    private func openCamera() {
        Task {
            do { try await storage.checkCanAddItem(in: space); showCamera = true }
            catch is PlanLimit { paywallReason = .items; showPaywall = true }
            catch { self.error = mediaErrorText(error) }
        }
    }

    private func open(_ item: MediaItem) {
        selected = item
    }

    private func saveAlbums() async {
        try? await storage.saveIndex(albums, file: Albums.file, in: space)
    }

    private func saveFacts() async {
        try? await storage.save(facts, in: space)
    }

    /// Works out the facts of every photo and video that has none yet, one
    /// at a time, saving every few so a lock loses little. A change to the
    /// library cancels it and starts another, which carries on from here.
    private func sort() async {
        guard entitlements.allows(.smartAlbums) else { sorting = nil; return }
        let todo = facts.needsScan(items.map(\.name))
        guard !todo.isEmpty else {
            sorting = nil
            if !facts.ungrouped.isEmpty {
                facts.groupFaces(in: facts.ungrouped)
                await saveFacts()
            }
            return
        }
        sorting = (0, todo.count)
        for (i, name) in todo.enumerated() {
            guard entitlements.allows(.smartAlbums), !Task.isCancelled else { sorting = nil; return }
            guard let found = await PhotoScanner.facts(of: MediaItem(name: name), storage: storage, space: space) else { break }
            // Half-looked-at (Vision stops when cancelled): the next sort redoes it.
            if Task.isCancelled { return }
            facts.photos[name] = found
            sorting?.done = i + 1
            if (i + 1) % 10 == 0 {
                facts.groupFaces(in: facts.ungrouped)
                await saveFacts()
            }
        }
        facts.groupFaces(in: facts.ungrouped)
        await saveFacts()
        if !Task.isCancelled { sorting = nil }
    }

    private func reload(animated: Bool) async {
        let new = ((try? await storage.mediaItems(in: space)) ?? []).filter(\.kind.isGalleryItem)
        freeUsed = try? await storage.userItemCount(in: space)
        var index = await storage.index(Albums.self, file: Albums.file, in: space, empty: Albums())
        let stored = index
        index.prune(keeping: Set(new.map(\.name)))
        albums = index
        if index != stored { await saveAlbums() }
        // Read once: after that the scan's own copy is the newest.
        if !factsLoaded {
            facts = await storage.photoFacts(in: space)
            factsLoaded = true
        }
        let storedFacts = facts
        facts.prune(keeping: Set(new.map(\.name)))
        if facts != storedFacts { await saveFacts() }
        added = (try? await storage.addedDates(in: space)) ?? added
        guard new != items || !loaded else { return }
        if animated, loaded {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Theme.bouncy) { items = new }
        } else {
            items = new
        }
        withAnimation(Theme.smooth) { loaded = true }
    }

    private func importPicked(_ picks: [PhotosPickerItem]) async {
        picked = []
        guard progress == nil else { return }
        withAnimation(Theme.smooth) { progress = ImportProgress(total: picks.count) }
        var identifiers: [String] = []
        var failure: String?
        var hitLimit = false
        for pick in picks {
            do {
                if let file = try await pick.loadTransferable(type: PickedFile.self) {
                    try await MediaImport.importFile(at: file.url, into: storage, space: space)
                    if let id = pick.itemIdentifier { identifiers.append(id) }
                    // Each one lands in the grid as it arrives.
                    await reload(animated: true)
                }
            } catch {
                if error is PlanLimit { hitLimit = true; break }
                failure = mediaErrorText(error)
                // Once the room is full, the rest can't fit either.
                if (error as? StorageError) == .noRoom { break }
            }
            progress?.done += 1
        }
        withAnimation(Theme.smooth) { progress = nil }
        await reload(animated: true)

        if hitLimit {
            // A mixed batch can fail an earlier import and later reach the
            // allowance. Present one modal, and leave originals untouched.
            paywallReason = .items
            showPaywall = true
            Haptics.play(.warning)
        } else if let failure {
            Haptics.play(.error)
            askAfterError = identifiers.isEmpty ? nil : identifiers
            error = failure
        } else if !identifiers.isEmpty {
            Haptics.play(.success)
            afterImport = .askDelete(identifiers)
        } else if !picks.isEmpty {
            Haptics.play(.success)
            toast = "Added to this space"
        }
    }

    private func deleteOriginals(_ identifiers: [String]) async {
        guard entitlements.allows(.deleteOriginals) else { showPaywall = true; return }
        switch await DeleteOriginals.run(identifiers: identifiers) {
        case .deleted:
            Haptics.play(.success)
            afterImport = .deleted
        case .denied:
            Haptics.play(.warning)
            afterImport = .denied
        case .cancelled:
            break
        }
    }
}

/// Library and Albums: two icon buttons in a pill, the chosen one white.
private struct PhotosTabs: View {
    @Binding var selection: MediaGalleryView.Tab
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            tab(.library, "Library", symbol: "photo.on.rectangle")
            tab(.albums, "Albums", symbol: "rectangle.stack")
        }
        .padding(4)
        .background(Capsule().fill(Theme.raised))
        .overlay(Capsule().stroke(Theme.hairline))
    }

    private func tab(_ value: MediaGalleryView.Tab, _ title: String, symbol: String) -> some View {
        let on = selection == value
        return Button {
            guard !on else { return }
            Haptics.play(.select)
            withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) { selection = value }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(on ? Color.black : Theme.primary)
            .frame(width: 76, height: 50)
            .background {
                if on { Capsule().fill(Color.white).matchedGeometryEffect(id: "thumb", in: thumb) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(SquishStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("photos.tab.\(value.rawValue)")
    }
}

/// One square of the grid, drawn from the stored thumbnail, which fades in
/// once it is read.
struct ThumbnailCell: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        Theme.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if item.kind != .image && item.kind != .video {
                    GlyphView(glyph: .files).frame(width: 22, height: 22).foregroundStyle(Theme.tertiary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .padding(5)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: item) {
                var data = try? await storage.readFile(named: item.thumbName, in: space)
                // Save to Casita writes files only; make the missing thumbnail once, here.
                if data == nil { data = await Thumbnail.makeMissing(for: item, storage: storage, space: space) }
                guard let data else { return }
                let decoded = UIImage(data: data)
                withAnimation(.easeOut(duration: 0.25)) { image = decoded }
            }
    }
}
