import SwiftUI

/// A folder in Files: its name and how much is in it.
struct FolderRow: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.primary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium)).lineLimit(1)
                Text(count == 0 ? "Empty" : counted(count, "item", "items")).font(.footnote).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .foregroundStyle(Theme.primary)
    }
}

/// Where to move a file: the top of Files or any folder, nested ones indented.
struct FolderPicker: View {
    let folders: [String]
    let current: String?
    var onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row("Files", depth: 0, target: nil, id: "move.root")
                ForEach(folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { path in
                    row(Folders.name(of: path), depth: path.split(separator: "/").count, target: path, id: "move.folder.\(Folders.name(of: path))")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Move to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .tint(.white)
    }

    private func row(_ name: String, depth: Int, target: String?, id: String) -> some View {
        Button {
            guard target != current else { return dismiss() }
            Haptics.play(.select)
            onPick(target)
            dismiss()
        } label: {
            HStack {
                Image(systemName: target == nil ? "tray.full" : "folder")
                Text(name)
                Spacer()
                if target == current { Image(systemName: "checkmark").foregroundStyle(Theme.secondary) }
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 18)
        }
        .accessibilityIdentifier(id)
    }
}

/// Writes a text file: a new one with a name, or one already in the space.
/// The text lives only in memory until it is saved into the space.
struct TextFileEditor: View {
    let storage: ReservedStorage
    let space: SpaceRef
    /// Nil for a new file.
    let item: MediaItem?
    var onSaved: (MediaItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Entitlements.self) private var entitlements
    @State private var name = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var showPaywall = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if item == nil {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
                        .accessibilityIdentifier("textEditor.name")
                }
                TextEditor(text: $text)
                    .focused($focused)
                    // What is typed here must not reach the keyboard's learned
                    // words or Writing Tools, which both live outside the space.
                    .autocorrectionDisabled()
                    .writingToolsBehavior(.disabled)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.surface))
                    .accessibilityIdentifier("textEditor.body")
            }
            .padding(Theme.gutter)
            .background(Theme.background)
            .navigationTitle(item?.name ?? "New text file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || !loaded)
                        .accessibilityIdentifier("textEditor.save")
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .paywall(isPresented: $showPaywall, reason: .items)
        .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
        .task {
            if let item, let data = try? await storage.readFile(named: item.name, in: space) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                focused = item == nil
            }
            loaded = true
        }
    }

    private func save() async {
        guard entitlements.allows(.add) else { showPaywall = true; return }
        saving = true
        defer { saving = false }
        do {
            let data = Data(text.utf8)
            let saved: MediaItem
            if let item {
                try await storage.writeFile(named: item.name, data: data, in: space)
                saved = item
            } else {
                let base = Albums.clean(name.replacingOccurrences(of: "/", with: "-"), otherwise: "Note")
                let file = base.lowercased().hasSuffix(".txt") ? base : base + ".txt"
                saved = MediaItem(name: try await storage.addUserFile(named: file, data: data, in: space))
            }
            Haptics.play(.success)
            onSaved(saved)
            dismiss()
        } catch {
            if error is PlanLimit { showPaywall = true; return }
            Haptics.play(.error)
            self.error = mediaErrorText(error)
        }
    }
}
