import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Everything in a space that is not a photo or video, in the person's own
/// folders, with text files they write here.
struct FilesView: View {
    let storage: ReservedStorage
    let space: SpaceRef
    /// The folder shown; nil is the top.
    var folder: String? = nil

    @Environment(Entitlements.self) private var entitlements
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var zoom
    @State private var items: [MediaItem] = []
    /// Photos, videos and files in this space, shown against the free allowance.
    @State private var freeUsed: Int?
    @State private var loaded = false
    @State private var selected: MediaItem?
    @State private var choosing = false
    @State private var showPaywall = false
    @State private var progress: ImportProgress?
    @State private var confirmDelete: MediaItem?
    @State private var error: String?
    @State private var toast: String?
    @State private var folders = Folders()
    @State private var openFolder: String?
    @State private var namingFolder = false
    @State private var folderName = ""
    @State private var renamingFolder: String?
    @State private var deletingFolder: String?
    @State private var moving: MediaItem?
    @State private var editing: TextEdit?

    /// A text file to write: a new one (no item) or one to change.
    struct TextEdit: Identifiable {
        var item: MediaItem?
        var id: String { item?.name ?? "new" }
    }

    private var title: String { folder.map(Folders.name) ?? "Files" }
    private var subfolders: [String] { folders.subfolders(of: folder) }

    private var detail: String? {
        let parts = [subfolders.isEmpty ? nil : counted(subfolders.count, "folder", "folders"),
                     items.isEmpty ? nil : counted(items.count, "file", "files")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    ScreenHeader(title: title, detail: detail)
                    if !entitlements.isSubscribed, let freeUsed, freeUsed > 0 {
                        FreeCountLine(used: freeUsed) { showPaywall = true }
                    }
                }
                if let progress {
                    ImportProgressBar(progress: progress)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if loaded, items.isEmpty, subfolders.isEmpty, progress == nil {
                    EmptyStateView(glyph: .files, line: "Documents you add stay in this space.") {
                        Button("Add files", action: add)
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityIdentifier("files.empty.add")
                        Button("New text file", action: newText)
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("files.empty.text")
                    }
                    .padding(.top, 72)
                    .transition(.opacity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("files.empty")
                }
                LazyVStack(spacing: 8) {
                    ForEach(subfolders, id: \.self) { path in
                        Button { openFolder = path } label: {
                            FolderRow(name: Folders.name(of: path), count: folders.files(under: path).count + folders.subfolders(of: path).count)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.98))
                        .contextMenu {
                            Button { folderName = Folders.name(of: path); renamingFolder = path } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) {
                                Haptics.play(.warning)
                                deletingFolder = path
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        .accessibilityIdentifier("files.folder.\(Folders.name(of: path))")
                    }
                    ForEach(items) { item in
                        Button { open(item) } label: {
                            FileRow(storage: storage, space: space, item: item)
                        }
                        .buttonStyle(PressableButtonStyle(scale: 0.98))
                        .matchedTransitionSource(id: item.id, in: zoom)
                        .contextMenu {
                            Button { moving = item } label: { Label("Move to folder", systemImage: "folder") }
                            Button(role: .destructive) {
                                Haptics.play(.warning)
                                confirmDelete = item
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                        .transition(reduceMotion ? AnyTransition.opacity : .move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("files.row.\(item.name)")
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files.screen")
        .holdsIdleLock(choosing || progress != nil)
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background)
        .foregroundStyle(Theme.primary)
        .preferredColorScheme(.dark)
        .collapsingTitle(title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: add) { Label("Add files", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("files.add.import")
                    Button(action: newText) { Label("New text file", systemImage: "doc.text") }
                        .accessibilityIdentifier("files.add.text")
                    Button { folderName = ""; namingFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                        .accessibilityIdentifier("files.add.folder")
                } label: { CircleIcon(symbol: "plus", fill: Theme.primary, tint: .black) }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("files.add")
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .navigationDestination(item: $openFolder) { path in
            FilesView(storage: storage, space: space, folder: path)
        }
        .sheet(item: $editing) { edit in
            TextFileEditor(storage: storage, space: space, item: edit.item) { saved in
                if edit.item == nil, folder != nil {
                    folders.move(saved.name, to: folder)
                    Task { await saveFolders() }
                }
                Task { await reload(animated: true) }
            }
        }
        .sheet(item: $moving) { item in
            FolderPicker(folders: folders.folders, current: folders.placement[item.name]) { target in
                folders.move(item.name, to: target)
                Task {
                    await saveFolders()
                    await reload(animated: true)
                }
                toast = "Moved to \(target.map(Folders.name) ?? "Files")"
            }
        }
        .alert("New folder", isPresented: $namingFolder) {
            TextField("Name", text: $folderName)
                .autocorrectionDisabled()
            Button("Create") {
                folders.create(folderName, in: folder)
                Task { await saveFolders() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $folderName)
                .autocorrectionDisabled()
            Button("Rename") {
                if let path = renamingFolder { folders.rename(path, to: folderName) }
                Task { await saveFolders() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deletingFolder.map { "Delete \(Folders.name(of: $0))?" } ?? "",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible,
            presenting: deletingFolder
        ) { path in
            Button("Delete folder", role: .destructive) { Task { await deleteFolder(path) } }
        } message: { path in
            let count = folders.files(under: path).count
            Text(count == 0 ? "It's empty." : count == 1 ? "The file in it is deleted too." : "The \(count) files in it are deleted too.")
        }
        .barToast($toast)
        .paywall(isPresented: $showPaywall, reason: .items)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await importFiles(result) }
        }
        .fullScreenCover(item: $selected) { item in
            MediaViewerView(storage: storage, space: space, item: item) { Task { await reload(animated: true) } }
                .navigationTransition(.zoom(sourceID: item.id, in: zoom))
        }
        .confirmationDialog(
            confirmDelete.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { target in
            Button("Delete", role: .destructive) { Task { await delete(target) } }
        }
        .alert("Couldn't add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
        // Back from a folder or the editor: what changed there shows here.
        .onAppear { Task { await reload(animated: loaded) } }
    }

    private func open(_ item: MediaItem) {
        if item.kind == .text { editing = TextEdit(item: item) } else { selected = item }
    }

    private func newText() {
        Task {
            do { try await storage.checkCanAddItem(in: space); editing = TextEdit(item: nil) }
            catch is PlanLimit { showPaywall = true }
            catch { self.error = mediaErrorText(error) }
        }
    }

    private func saveFolders() async {
        try? await storage.saveIndex(folders, file: Folders.file, in: space)
    }

    private func deleteFolder(_ path: String) async {
        for name in folders.delete(path) { try? await storage.deleteItem(MediaItem(name: name), in: space) }
        await saveFolders()
        Haptics.play(.thud)
        await reload(animated: true)
    }

    private func add() {
        Task {
            do { try await storage.checkCanAddItem(in: space); choosing = true }
            catch is PlanLimit { showPaywall = true }
            catch { self.error = mediaErrorText(error) }
        }
    }

    private func reload(animated: Bool) async {
        let all = ((try? await storage.mediaItems(in: space)) ?? []).filter { !$0.kind.isGalleryItem }
        freeUsed = try? await storage.userItemCount(in: space)
        var index = await storage.index(Folders.self, file: Folders.file, in: space, empty: Folders())
        let stored = index
        index.prune(keeping: Set(all.map(\.name)))
        if index != folders { withAnimation(Theme.smooth) { folders = index } }
        if index != stored { await saveFolders() }
        let new = all.filter { index.isFile($0.name, in: folder) }
        guard new != items || !loaded else { return }
        if animated, loaded {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Theme.bouncy) { items = new }
        } else {
            items = new
        }
        withAnimation(Theme.smooth) { loaded = true }
    }

    private func importFiles(_ result: Result<[URL], any Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty, progress == nil else { return }
        withAnimation(Theme.smooth) { progress = ImportProgress(total: urls.count) }
        var added = 0
        var failure: String?
        var hitLimit = false
        for url in urls {
            do {
                // The user's own file stays where it is; only our protected copy is consumed.
                let item = try await MediaImport.importFile(at: try MediaTemp.copyIn(url), into: storage, space: space)
                if folder != nil {
                    folders.move(item.name, to: folder)
                    await saveFolders()
                }
                added += 1
                await reload(animated: true)
            } catch {
                if error is PlanLimit { hitLimit = true; break }
                failure = mediaErrorText(error)
                if (error as? StorageError) == .noRoom { break }
            }
            progress?.done += 1
        }
        withAnimation(Theme.smooth) { progress = nil }
        await reload(animated: true)
        if hitLimit {
            Haptics.play(.warning)
            showPaywall = true
        } else if let failure {
            Haptics.play(.error)
            error = failure
        } else if added > 0 {
            Haptics.play(.success)
            toast = added == 1 ? "Added to this space" : "\(added) files added"
        }
    }

    private func delete(_ item: MediaItem) async {
        do {
            try await storage.deleteItem(item, in: space)
            Haptics.play(.thud)
            await reload(animated: true)
        } catch {
            Haptics.play(.error)
            toast = mediaErrorText(error)
        }
    }
}

/// One file: its first page when it has one (PDFs), otherwise the Files
/// glyph, then its name and kind.
private struct FileRow: View {
    let storage: ReservedStorage
    let space: SpaceRef
    let item: MediaItem
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised)
                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    GlyphView(glyph: .files, lineWidth: 1.7)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(Theme.primary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kind)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .task(id: item) {
            guard item.kind == .pdf, let data = try? await storage.readFile(named: item.thumbName, in: space) else { return }
            let decoded = UIImage(data: data)
            withAnimation(.easeOut(duration: 0.25)) { thumb = decoded }
        }
    }

    /// "PDF document", "Plain text", and so on, from the name alone.
    private var kind: String {
        item.utType.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "File"
    }
}
