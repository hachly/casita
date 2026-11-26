import SwiftUI

/// The spaces under this one. Every space has this screen and can make
/// spaces of its own; nothing here says whether this space is the top, and
/// nothing counts spaces anywhere else.
struct SpacesListView: View {
    let parent: SpaceRef
    @Environment(AppModel.self) private var model
    @Environment(Entitlements.self) private var entitlements
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var names: [String] = []
    @State private var loaded = false
    @State private var showPaywall = false
    @State private var creating = false
    @State private var editing = false
    @State private var switching: String?
    /// Opened once the switch prompt has gone.
    @State private var switchTo: String?
    @State private var deleting: String?
    @State private var toast: String?

    var body: some View {
        let shown = loaded || reduceMotion
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    ScreenHeader(title: "Spaces")
                    if !names.isEmpty {
                        Button(editing ? "Done" : "Edit") {
                            Haptics.play(.select)
                            withAnimation(Theme.snappy) { editing.toggle() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(editing ? Theme.primary : Theme.secondary)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("spaces.edit")
                    }
                }
                .padding(.bottom, 14)

                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    row(name)
                        .reveal(index, active: shown)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                // No spaces yet: the same empty state as Photos and Files,
                // with the button below.
                if loaded, names.isEmpty {
                    EmptyStateView(glyph: .spaces, line: "A space you make here opens with its own code.") {}
                        .padding(.top, 72)
                        .accessibilityIdentifier("spaces.empty")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button {
                if entitlements.allows(.createSpace) { creating = true } else { showPaywall = true }
            } label: {
                Label("New space", systemImage: "plus")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, Theme.gutter)
            .column()
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Theme.background)
            .accessibilityIdentifier("spaces.new")
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .collapsingTitle("Spaces")
        .task { await reload() }
        .barToast($toast)
        .sheet(isPresented: $creating) {
            NewSpaceSheet(parent: parent, existing: names) { name in
                Task { await reload() }
                toast = "\(name) is ready"
            }
            .coverWhenInactive()
        }
        .paywall(isPresented: $showPaywall, reason: .spaces)
        .sheet(item: $deleting) { name in
            DeleteSpaceSheet(parent: parent, name: name) {
                Task { await reload() }
                toast = "\(name) deleted"
            }
            .coverWhenInactive()
        }
        .sheet(item: $switching, onDismiss: {
            if let name = switchTo {
                switchTo = nil
                open(name)
            }
        }) { name in
            PromptSheet(glyph: .house, title: "Switch to \(name)?",
                        message: "To come back, lock Casita and enter this space's code.",
                        confirmTitle: "Switch", identifier: "spaces.switch") { switchTo = name }
            .coverWhenInactive()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spaces.screen")
    }

    @ViewBuilder private func row(_ name: String) -> some View {
        if editing {
            CasitaRow(glyph: .house, title: name) {
                Button {
                    Haptics.play(.warning)
                    deleting = name
                } label: {
                    Text("Delete")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(Theme.raised))
                }
                .buttonStyle(PressableButtonStyle(scale: 0.92))
                .accessibilityLabel("Delete \(name)")
                .accessibilityIdentifier("spaces.delete.\(name)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("spaces.row.\(name)")
        } else {
            Button {
                switching = name
            } label: {
                CasitaRow(glyph: .house, title: name)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.98))
            .contextMenu {
                Button("Switch to \(name)", systemImage: "arrow.right") { switching = name }
                Button("Delete \(name)", systemImage: "trash", role: .destructive) { deleting = name }
            }
            .accessibilityIdentifier("spaces.row.\(name)")
        }
    }

    private func reload() async {
        guard let storage = model.storage else { return }
        let found = (try? await storage.children(of: parent)) ?? []
        withAnimation(Theme.snappy) {
            names = found
            if found.isEmpty { editing = false }
        }
        loaded = true
    }

    private func open(_ name: String) {
        Task {
            do {
                try await model.switchTo(name, under: parent)
            } catch {
                Haptics.play(.error)
                toast = "Couldn't open \(name)"
            }
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}

/// Names the new space, then takes its code twice, with any unlock method.
private struct NewSpaceSheet: View {
    let parent: SpaceRef
    /// Names already used under this space; two spaces here can't share one.
    var existing: [String]
    var onCreated: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var naming = true
    @State private var method = EntryView.Method.numbers
    @State private var text = ""
    @State private var firstCode: String?
    @State private var message: String?
    @State private var busy = false
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        CasitaSheetFrame(title: naming ? "New space" : trimmed, lead: lead, busy: busy, identifier: "spaces.new.screen") {
            if naming {
                VStack(spacing: 14) {
                    TextField("", text: $name, prompt: Text("Name").foregroundStyle(Theme.tertiary))
                        .font(.title3.weight(.medium))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit(next)
                        .focused($nameFocused)
                        .padding(.horizontal, 22)
                        .frame(height: 58)
                        .background(Capsule().fill(Theme.raised))
                        .overlay(Capsule().strokeBorder(nameFocused ? Color.white.opacity(0.22) : Theme.hairline))
                        .onAppear { nameFocused = true }
                        .accessibilityIdentifier("spaces.new.name")
                    SheetMessage(text: message)
                    Spacer(minLength: 0)
                    Button("Next", action: next)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(trimmed.isEmpty)
                        .accessibilityIdentifier("spaces.new.next")
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                VStack(spacing: 14) {
                    SheetMessage(text: message)
                    CodeInput(method: $method, text: $text,
                              actionTitle: firstCode == nil ? "Next" : "Create space",
                              minimumLength: method == .dots ? CodeRules.minimumDots : CodeRules.minimumDigits, onSubmit: step)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
    }

    private var lead: String {
        if naming { return "Only this space sees the name." }
        return firstCode == nil ? "Choose its code. Any unlock method works." : "Type the code again."
    }

    private func next() {
        guard !trimmed.isEmpty else { return }
        guard !existing.contains(trimmed) else {
            Haptics.play(.error)
            message = "A space under this one already has that name."
            return
        }
        Haptics.play(.soft)
        message = nil
        withAnimation(Theme.smooth) { naming = false }
    }

    private func step(_ code: String) {
        text = ""
        guard let first = firstCode else {
            Haptics.play(.soft)
            withAnimation(Theme.snappy) {
                firstCode = code
                message = nil
            }
            return
        }
        withAnimation(Theme.snappy) { firstCode = nil }
        guard code == first else {
            Haptics.play(.error)
            message = "The two codes didn't match. Start again."
            return
        }
        guard !model.waits.isWaiting else {
            // Whether a code is taken is a guess against every space.
            Haptics.play(.warning)
            message = "No new code can be set during a wait."
            return
        }
        create(code: code)
    }

    private func create(code: String) {
        guard let storage = model.storage else { return }
        let name = trimmed
        busy = true
        Task {
            // A new code is checked against every space, and either answer
            // says something about them: each one counts as a try.
            model.waits.registerWrongAttempt()
            do {
                // A quarter of this space's free room; a size pick comes with Settings.
                let free = try await storage.freeBytes(in: parent)
                let chunks = max(1, Int(free / Int64(ReservedStorage.chunkPlain)) / 4)
                _ = try await storage.createChild(of: parent, name: name, code: code, chunks: chunks)
                Haptics.play(.success)
                onCreated(name)
                dismiss()
            } catch StorageError.codeInUse {
                Haptics.play(.error)
                message = "That code is already used. Pick another."
            } catch StorageError.noRoom {
                Haptics.play(.error)
                message = "No room left in this space."
            } catch StorageError.noSlots {
                Haptics.play(.error)
                message = "No more spaces fit under this one."
            } catch {
                Haptics.play(.error)
                message = "The space couldn't be made."
            }
            busy = false
        }
    }
}

/// Deleting needs the child's own code, and takes every space under it
/// too; the warning counts them first.
private struct DeleteSpaceSheet: View {
    let parent: SpaceRef
    let name: String
    var onDone: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var under: Int?
    @State private var method = EntryView.Method.numbers
    @State private var text = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        CasitaSheetFrame(title: "Delete \(name)", busy: busy, identifier: "spaces.delete.screen") {
            VStack(alignment: .leading, spacing: 14) {
                Text(Self.warning(name: name, spacesUnder: under))
                    .font(.headline)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("spaces.delete.warning")
                Text("This can't be undone. Type the code of \(name) to delete it.")
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SheetMessage(text: message)
                CodeInput(method: $method, text: $text, actionTitle: "Delete", destructive: true, minimumLength: 1, onSubmit: confirm)
            }
        }
        .task { await count() }
    }

    /// Before the count is in, the warning still says everything under it goes.
    static func warning(name: String, spacesUnder count: Int?) -> String {
        switch count {
        case nil: "This deletes \(name) and every space under it, and everything in them."
        case 0?: "This deletes \(name) and everything in it."
        case 1?: "This deletes \(name), the space under it, and everything in them."
        case let count?: "This deletes \(name), the \(count) spaces under it, and everything in them."
        }
    }

    /// A parent holds its children's keys, so it can count what is under one.
    private func count() async {
        guard let storage = model.storage, let child = try? await storage.openChild(of: parent, named: name) else { return }
        let found = try? await storage.spaceCount(under: child)
        await storage.lock(child)
        withAnimation(Theme.snappy) { under = found }
        Haptics.play(.warning)
    }

    private func confirm(_ code: String) {
        guard let storage = model.storage else { return }
        text = ""
        guard !model.waits.isWaiting else {
            Haptics.play(.warning)
            message = "No code works during a wait."
            return
        }
        message = nil
        busy = true
        Task {
            // Opened without its code just to compare; closed again if anything fails.
            var compared: SpaceRef?
            do {
                let child = try await storage.openChild(of: parent, named: name)
                compared = child
                let opened = try await storage.unlock(code: code)
                guard opened == child else {
                    await storage.lock(child)
                    // Another space's code opened that space; close it again,
                    // unless it is this one, which is open on screen.
                    if let opened, opened != parent { await storage.lock(opened) }
                    model.waits.registerWrongAttempt()
                    Haptics.play(.error)
                    message = "That isn't the code of \(name)."
                    busy = false
                    return
                }
                try await storage.deleteChild(of: parent, named: name)
                Haptics.play(.thud)
                onDone()
                dismiss()
            } catch {
                if let compared { await storage.lock(compared) }
                Haptics.play(.error)
                message = "\(name) couldn't be deleted."
            }
            busy = false
        }
    }
}
