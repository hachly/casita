import SwiftUI

/// A code typed with any unlock method, as on the entry screen: digits, dots
/// or a password. Dots submit when the finger lifts, the others with the
/// button. Codes look the same as the entry screen makes them.
struct CodeInput: View {
    @Binding var method: EntryView.Method
    @Binding var text: String
    var actionTitle: String
    var destructive = false
    /// Characters for digits and passwords, dots for dots.
    var minimumLength: Int
    var onSubmit: (String) -> Void
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    /// Always 3×3 to begin with, as on the entry screen.
    @State private var dotsGrid = 3

    var body: some View {
        VStack(spacing: 18) {
            EntryMethodSwitch(method: $method, haptics: model.haptics, identifierPrefix: "code.method")
                .onChange(of: method) {
                    text = ""
                    dotsGrid = 3
                }
                .frame(maxWidth: .infinity)

            if method == .dots {
                DotsGridPicker(size: $dotsGrid, haptics: model.haptics)
                DotsPad(gridSize: dotsGrid, hideLine: model.lockSettings.hideDotsLine, haptics: model.haptics,
                        minimumDots: minimumLength) { onSubmit($0) }
                if minimumLength > 1 {
                    Text("Join at least \(minimumLength) dots")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            } else {
                SecureField(method == .numbers ? "Code" : "Password", text: $text,
                            prompt: Text(method == .numbers ? "Code" : "Password").foregroundStyle(Theme.tertiary))
                    .font(.title3.weight(.medium))
                    .keyboardType(method == .numbers ? .numberPad : .default)
                    .textContentType(.oneTimeCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .focused($focused)
                    .padding(.horizontal, 22)
                    .frame(height: 58)
                    .background(Capsule().fill(Theme.raised))
                    .overlay(Capsule().strokeBorder(focused ? Color.white.opacity(0.22) : Theme.hairline))
                    .id(method)
                    .onAppear { focused = true }
                    .onChange(of: text) {
                        if method == .numbers, text.contains(where: { !$0.isNumber }) { text = text.filter(\.isNumber) }
                    }
                    .accessibilityIdentifier("code.field")
                Spacer(minLength: 0)
                Group {
                    if destructive {
                        Button(actionTitle, action: submit).buttonStyle(RaisedButtonStyle(destructive: true))
                    } else {
                        Button(actionTitle, action: submit).buttonStyle(PrimaryButtonStyle())
                    }
                }
                .disabled(text.count < minimumLength)
                .accessibilityIdentifier("code.submit")
            }
        }
    }

    private func submit() {
        guard text.count >= minimumLength else { return }
        onSubmit(text)
    }
}

/// A new code for the open space, typed twice.
struct ChangeCodeSheet: View {
    let space: SpaceRef
    let settings: SettingsModel
    var onChanged: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var method = EntryView.Method.numbers
    @State private var text = ""
    @State private var firstEntry: String?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        CasitaSheetFrame(title: "Change code",
                         lead: firstEntry == nil ? "Type a new code for this space." : "Type the new code again.",
                         busy: busy, identifier: "settings.changeCode.screen") {
            VStack(spacing: 14) {
                SheetMessage(text: message)
                CodeInput(
                    method: $method, text: $text,
                    actionTitle: firstEntry == nil ? "Next" : "Change code",
                    minimumLength: method == .dots ? CodeRules.minimumDots : CodeRules.minimumDigits, onSubmit: step
                )
            }
        }
    }

    private func step(_ code: String) {
        text = ""
        guard let first = firstEntry else {
            Haptics.play(.soft)
            withAnimation(Theme.snappy) {
                firstEntry = code
                message = nil
            }
            return
        }
        withAnimation(Theme.snappy) { firstEntry = nil }
        guard code == first else {
            Haptics.play(.error)
            message = "The two codes didn't match. Start again."
            return
        }
        guard !model.waits.isWaiting else {
            Haptics.play(.warning)
            message = "No code can change during a wait."
            return
        }
        busy = true
        Task {
            // A new code is checked against every space, and either answer
            // says something about them: each one counts as a try.
            model.waits.registerWrongAttempt()
            do {
                try await settings.changeCode(to: code, for: space)
                Haptics.play(.success)
                onChanged()
                dismiss()
            } catch StorageError.codeInUse {
                Haptics.play(.error)
                message = "That code is already used. Pick another."
            } catch {
                Haptics.play(.error)
                message = "The code couldn't be changed."
            }
            busy = false
        }
    }
}

/// Deletes the open space and every space under it, after a warning that
/// counts them and the space's own code. Then Casita locks.
struct DeleteThisSpaceSheet: View {
    let space: SpaceRef
    let settings: SettingsModel
    @Environment(AppModel.self) private var model
    @State private var under: Int?
    @State private var method = EntryView.Method.numbers
    @State private var text = ""
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        CasitaSheetFrame(title: "Delete this space", busy: busy, identifier: "settings.deleteSpace.screen") {
            if let under {
                VStack(alignment: .leading, spacing: 14) {
                    Text(Self.warning(spacesUnder: under))
                        .font(.headline)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.deleteSpace.warning")
                    Text("This can't be undone. Type this space's code to delete it.")
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SheetMessage(text: message)
                    CodeInput(method: $method, text: $text, actionTitle: "Delete", destructive: true, minimumLength: 1, onSubmit: confirm)
                }
            }
        }
        .task {
            under = await settings.spaceCount(under: space)
            Haptics.play(.warning)
        }
    }

    static func warning(spacesUnder count: Int) -> String {
        switch count {
        case 0: "This deletes this space and everything in it."
        case 1: "This deletes this space, the space under it, and everything in them."
        default: "This deletes this space, the \(count) spaces under it, and everything in them."
        }
    }

    private func confirm(_ code: String) {
        text = ""
        guard !model.waits.isWaiting else {
            Haptics.play(.warning)
            message = "No code works during a wait."
            return
        }
        message = nil
        busy = true
        Task {
            do {
                if try await settings.delete(space, confirmingWith: code) {
                    Haptics.play(.thud)
                    model.lock()
                } else {
                    model.waits.registerWrongAttempt()
                    Haptics.play(.error)
                    message = "Wrong code"
                }
            } catch {
                Haptics.play(.error)
                message = "This space couldn't be deleted."
            }
            busy = false
        }
    }
}

/// Shows a new recovery sentence, then re-seals this space and the spaces
/// under it to it. Nothing changes until the person says they saved it.
struct NewRecoveryKeySheet: View {
    let phrase: RecoveryPhrase
    let space: SpaceRef
    let settings: SettingsModel
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        CasitaSheetFrame(title: nil, busy: saving, padded: false, identifier: "settings.newRecoveryKey.screen") {
            RecoveryKeyView(phrase: phrase) { await save() }
        }
        .interactiveDismissDisabled()
        .alert("The new key couldn't be saved", isPresented: $failed) {
            Button("OK") {}
        } message: {
            Text("Try again.")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let key = await Task.detached(priority: .userInitiated) { [phrase] in RecoveryKey(phrase: phrase) }.value
            try await settings.setRecoveryKey(key, from: space)
            Haptics.play(.success)
            onSaved()
            dismiss()
        } catch {
            Haptics.play(.error)
            failed = true
        }
    }
}

// MARK: - Frames

/// The frame every Casita sheet uses: black, a round close button, a big
/// title, then the content, whose main button sits at the bottom.
struct CasitaSheetFrame<Content: View>: View {
    let title: String?
    var lead: String? = nil
    var busy = false
    /// False when the content brings its own padding.
    var padded = true
    var identifier: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.raised))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle(scale: 0.88))
                .disabled(busy)
                .opacity(busy ? 0.3 : 1)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("sheet.close")
            }
            .padding(.horizontal, padded ? 0 : Theme.gutter)
            if let title {
                Text(title)
                    .font(.casitaTitle)
                    .tracking(-0.6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if let lead {
                Text(lead)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(Theme.snappy, value: lead)
                    .padding(.top, 8)
            }
            Group {
                if busy {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(.top, title == nil ? 0 : 24)
            .animation(Theme.snappy, value: busy)
        }
        .padding(.horizontal, padded ? Theme.gutter : 0)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Theme.primary)
        .background(Theme.background.ignoresSafeArea())
        .presentationBackground(Theme.background)
        .interactiveDismissDisabled(busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// A short question with one main action and Cancel: a small sheet that
/// sizes itself to its words.
struct PromptSheet: View {
    var glyph: Glyph? = nil
    var symbol: String? = nil
    var tint = Theme.primary
    var title: String
    var message: String?
    var confirmTitle: String
    var destructive = false
    /// nil for a notice with just one button.
    var cancelTitle: String? = "Cancel"
    var identifier: String
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var height: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if glyph != nil || symbol != nil {
                Group {
                    if let glyph {
                        GlyphView(glyph: glyph, lineWidth: 1.8).frame(width: 26, height: 26)
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 21, weight: .semibold))
                    }
                }
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.raised))
                .padding(.bottom, 18)
            }
            Text(title)
                .font(.casitaTitle2)
                .tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            VStack(spacing: 6) {
                Group {
                    if destructive {
                        Button(confirmTitle) { confirm() }.buttonStyle(RaisedButtonStyle(destructive: true))
                    } else {
                        Button(confirmTitle) { confirm() }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                .accessibilityIdentifier("\(identifier).confirm")
                if let cancelTitle {
                    Button(cancelTitle) { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("\(identifier).cancel")
                }
            }
            .padding(.top, 28)
        }
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(identifier).screen")
    }

    private func confirm() {
        onConfirm()
        dismiss()
    }
}

/// One line for what went wrong; keeps its height when empty.
struct SheetMessage: View {
    var text: String?

    var body: some View {
        Text(text ?? " ")
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.danger)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.opacity)
            .animation(Theme.snappy, value: text)
            .accessibilityIdentifier("sheet.message")
    }
}

extension View {
    /// Sheets sit above the app's privacy cover, so they bring their own for
    /// the app switcher snapshot.
    func coverWhenInactive() -> some View { modifier(InactiveCover()) }
}

private struct InactiveCover: ViewModifier {
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content.overlay {
            if phase != .active { Color.black.ignoresSafeArea() }
        }
    }
}
