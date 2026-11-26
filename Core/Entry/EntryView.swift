import Combine
import SwiftUI

/// The one screen where a code for any space is entered. It looks and
/// behaves the same whichever space the code opens, and always starts on
/// the number pad.
///
/// Every attempt, right, decoy or wrong, shows the same checking animation
/// for as long as the storage takes, and nothing on screen differs until
/// the result is in.
struct EntryView: View {
    let model: any EntryController
    @State private var method: Method = .numbers
    /// Always 3×3 on arrival; nothing remembers another size.
    @State private var dotsGrid = 3
    @State private var entered = ""
    @State private var shake = 0
    @State private var message: String?
    @State private var now = Date.now
    @State private var confirmStartOver = false
    /// When the current check began, so its wave starts the same way every time.
    @State private var checkStart = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// One name for each everywhere (entry, setup, Settings). Nothing stores which one a space uses.
    enum Method: String, CaseIterable { case numbers = "Numbers", dots = "Dots", letters = "Password" }

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // Read through `now`, so the screen refreshes every second of a wait.
        let until = model.waits.waitUntil.flatMap { $0 > now ? $0 : nil }
        let waiting = until != nil
        WideReader { split in
            if let split {
                // A wide screen (an open iPhone Duo): the method and the code
                // so far on the leading half, the pad on the trailing half.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        mark
                        Spacer(minLength: 10)
                        controls(until: until)
                        Spacer(minLength: 10)
                        // Balances the logo, so the controls sit in the middle.
                        Color.clear.frame(height: 42)
                    }
                    .padding(.horizontal, Theme.gutter)
                    .frame(width: split)
                    padArea(waiting: waiting, alignment: .center)
                        .padding(.horizontal, Theme.gutter)
                        .padding(.vertical, 16)
                }
            } else {
                VStack(spacing: 0) {
                    mark
                    Spacer(minLength: 10).frame(maxHeight: 56)
                    controls(until: until)
                    padArea(waiting: waiting, alignment: method == .letters ? .top : method == .dots ? .center : .bottom)
                        .padding(.top, method == .letters ? 8 : 16)
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .disabled(model.checking || waiting)
        .onReceive(tick) { now = $0 }
        .onChange(of: method) {
            entered = ""
            dotsGrid = 3
            message = nil
        }
        .onChange(of: entered) { _, new in if !new.isEmpty { message = nil } }
        // A half-typed code, or one whose check was cut short by leaving,
        // isn't waiting on screen when Casita comes back.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { entered = "" }
        }
        .onChange(of: waiting) { was, isWaiting in
            // The wait is over: a soft beat, and codes work again.
            if was, !isWaiting { play(.soft) }
        }
        .overlay(alignment: .topTrailing) {
            if model.offersForgotCode {
                Button("Forgot code?") { model.forgotCode() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 16)
                    .padding(.trailing, Theme.gutter)
                    .disabled(model.checking)
                    .accessibilityIdentifier("entry.forgot")
            }
        }
        // A cover, not a sheet: a sheet leaves the logo and "Forgot code?"
        // showing behind the clock.
        .fullScreenCover(isPresented: $confirmStartOver) {
            StartOverSheet(haptics: model.haptics) { model.startOver() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry.screen")
    }

    // MARK: Pieces

    private var mark: some View {
        CasitaMark()
            .frame(width: 30, height: 30)
            .padding(.top, 12)
            .accessibilityHidden(true)
    }

    /// The method first, then what belongs to it, in the order setup uses:
    /// its grid sizes, the code so far, a message. The pad comes after.
    private func controls(until: Date?) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                EntryMethodSwitch(method: $method, haptics: model.haptics)
                if method == .dots {
                    DotsGridPicker(size: $dotsGrid, haptics: model.haptics)
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                }
            }
            indicator(until: until)
                .frame(height: 68)
                .padding(.top, 8)
            Text(message ?? model.reminder ?? " ")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(height: 24)
                .contentTransition(.opacity)
                .animation(Theme.snappy, value: message)
                .accessibilityIdentifier("entry.message")
        }
    }

    private func padArea(waiting: Bool, alignment: Alignment) -> some View {
        pad
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .opacity(waiting ? 0.25 : model.checking ? 0.6 : 1)
            .animation(Theme.smooth, value: waiting)
            .animation(Theme.snappy, value: model.checking)
    }

    @ViewBuilder private var pad: some View {
        switch method {
        case .numbers:
            NumberPad(entered: $entered, haptics: model.haptics, onSubmit: submit, onFaceID: faceID,
                      onStartOver: { confirmStartOver = true })
        case .dots:
            DotsPad(gridSize: dotsGrid, hideLine: model.hideDotsLine, haptics: model.haptics, onSubmit: { submit(code: $0) })
                .transition(.opacity)
        case .letters:
            PasswordField(text: $entered, onSubmit: submit)
                .transition(.opacity)
        }
    }

    /// The code so far as dots, a calm countdown during a wait, or, for
    /// dots and passwords, nothing until a code is being checked.
    @ViewBuilder private func indicator(until: Date?) -> some View {
        if let until {
            let text = Self.countdown(max(1, Int(until.timeIntervalSince(now).rounded(.up))))
            VStack(spacing: 2) {
                Text("Try again in")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.secondary)
                Text(text)
                    .font(.system(size: 36, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Theme.snappy, value: text)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("entry.wait")
        } else {
            let numbers = method == .numbers
            CodeDots(
                slots: numbers ? min(max(6, entered.count), 16) : (model.checking ? 6 : 0),
                filled: numbers ? entered.count : 6,
                checking: model.checking,
                checkStart: checkStart,
                reduceMotion: reduceMotion
            )
            .keyframeAnimator(initialValue: 0.0, trigger: shake) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-12, duration: 0.06)
                    LinearKeyframe(10, duration: 0.08)
                    LinearKeyframe(-8, duration: 0.08)
                    LinearKeyframe(5, duration: 0.07)
                    LinearKeyframe(-2, duration: 0.06)
                    LinearKeyframe(0, duration: 0.05)
                }
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: Actions

    private func submit() { submit(code: entered) }

    private func submit(code: String) {
        guard !code.isEmpty, !model.checking, !model.waits.isWaiting else { return }
        message = nil
        checkStart = .now
        Task {
            let opened = await model.submit(code: code)
            // Everything below happens only once the result is in.
            if !opened {
                entered = ""
                if !reduceMotion { shake += 1 }
                play(.error)
                message = model.waits.isWaiting ? nil : "Wrong code"
            }
        }
    }

    private func faceID() {
        guard !model.checking else { return }
        message = nil
        Task {
            switch await model.unlockWithFaceID() {
            case .opened: break
            case .notSetUp:
                play(.warning)
                message = "Face ID isn't set up"
            case .failed:
                play(.warning)
                message = "Face ID didn't work"
            }
        }
    }

    /// Honours the entry screen's own switch as well as the app-wide one.
    private func play(_ kind: Haptics.Kind) {
        if model.haptics { Haptics.play(kind) }
    }

    /// "0:59", "14:59", "1:00:00".
    static func countdown(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Method switch

/// The unlock method switch: number pad, dots or keyboard.
struct EntryMethodSwitch: View {
    @Binding var method: EntryView.Method
    var haptics = true
    /// "entry.method" on the entry screen; other screens pass their own.
    var identifierPrefix = "entry.method"

    var body: some View {
        EntrySegments(options: EntryView.Method.allCases, selection: $method, haptics: haptics,
                      title: \.rawValue, identifier: { "\(identifierPrefix).\(Self.name($0))" })
    }

    static func name(_ method: EntryView.Method) -> String {
        switch method {
        case .numbers: "numbers"
        case .dots: "dots"
        case .letters: "password"
        }
    }
}

// MARK: - Code dots

/// Six rings that fill with a pop as digits arrive, and more once a code
/// is longer. While a code is checked they ripple in a wave that starts the
/// same way and runs the same for every attempt.
private struct CodeDots: View {
    var slots: Int
    var filled: Int
    var checking: Bool
    /// Set just before the check begins, so the first frame is already right.
    var checkStart: Date
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: !checking)) { timeline in
            let t = timeline.date.timeIntervalSince(checkStart)
            HStack(spacing: slots > 10 ? 10 : 14) {
                ForEach(0..<slots, id: \.self) { i in
                    let wave = checking ? Self.wave(t, i) : 0
                    CodeDot(filled: i < filled, reduceMotion: reduceMotion)
                        .offset(y: reduceMotion ? 0 : -7 * wave)
                        .opacity(checking ? 0.4 + 0.6 * wave : 1)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(Theme.snappy, value: slots)
        }
    }

    /// A bump that travels left to right, once every 0.6 s.
    static func wave(_ t: TimeInterval, _ i: Int) -> Double {
        let phase = (t / 0.6 - Double(i) * 0.1).truncatingRemainder(dividingBy: 1)
        guard phase >= 0, phase < 0.45 else { return 0 }
        return sin(phase / 0.45 * .pi)
    }
}

private struct CodeDot: View {
    var filled: Bool
    var reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(filled ? 0 : 0.3), lineWidth: 1.5)
            Circle().fill(Color.white).scaleEffect(filled ? 1 : 0.001)
        }
        .frame(width: 14, height: 14)
        .animation(filled && !reduceMotion ? .spring(response: 0.3, dampingFraction: 0.42) : .smooth(duration: 0.2), value: filled)
    }
}

// MARK: - Number pad

/// Digits on round grey keys, Face ID bottom left, a white confirm key
/// bottom right, and Delete under the zero. One light tap per press.
struct NumberPad: View {
    @Binding var entered: String
    var haptics = true
    var onSubmit: () -> Void
    var onFaceID: () -> Void
    /// Held for three seconds on the Face ID key.
    var onStartOver: () -> Void = {}

    /// The full key size; smaller screens get smaller keys so the pad fits.
    static let keySize: CGFloat = 76

    var body: some View {
        ViewThatFits(in: .vertical) {
            keys(Self.keySize)
            keys(68)
            keys(60)
        }
    }

    private func keys(_ size: CGFloat) -> some View {
        let across = (size * 0.34).rounded()
        return VStack(spacing: (size * 0.18).rounded()) {
            // Plain rows, no ForEach. SwiftUI evaluated ForEach
            // items off the main actor inside ViewThatFits (seen under UI
            // tests), which trips Swift 6's isolation check and crashes.
            HStack(spacing: across) { digit("1", size: size); digit("2", size: size); digit("3", size: size) }
            HStack(spacing: across) { digit("4", size: size); digit("5", size: size); digit("6", size: size) }
            HStack(spacing: across) { digit("7", size: size); digit("8", size: size); digit("9", size: size) }
            HStack(spacing: across) {
                FaceIDKey(size: size, haptics: haptics, onTap: onFaceID, onHold: onStartOver)
                digit("0", size: size)
                Button(action: onSubmit) {
                    Image(systemName: "checkmark").font(.system(size: size * 0.33, weight: .bold))
                }
                .buttonStyle(KeyStyle(size: size, fill: .white, pressedFill: Color(white: 0.78), foreground: .black, haptics: haptics))
                .accessibilityLabel("OK")
                .accessibilityIdentifier("entry.key.ok")
            }
            Button {
                if !entered.isEmpty { entered.removeLast() }
            } label: {
                Text("Delete")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: size + 20, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TextKeyStyle(haptics: haptics))
            .opacity(entered.isEmpty ? 0 : 1)
            .disabled(entered.isEmpty)
            .animation(Theme.snappy, value: entered.isEmpty)
            .accessibilityIdentifier("entry.key.delete")
        }
    }

    private func digit(_ key: String, size: CGFloat) -> some View {
        Button {
            if entered.count < 32 { entered += key }
        } label: {
            Text(key).font(.system(size: (size * 0.42).rounded(), weight: .medium, design: .rounded))
        }
        .buttonStyle(KeyStyle(size: size, haptics: haptics))
        .accessibilityIdentifier("entry.key.\(key)")
    }
}

/// A round key that sinks and brightens under the finger with a spring,
/// and taps once as it goes down.
private struct KeyStyle: ButtonStyle {
    var size: CGFloat
    var fill = Theme.raised
    var pressedFill = Color(white: 0.22)
    var foreground = Theme.primary
    var haptics = true

    func makeBody(configuration: Configuration) -> some View {
        KeyFace(configuration: configuration, style: self)
    }
}

private struct KeyFace: View {
    let configuration: ButtonStyleConfiguration
    let style: KeyStyle

    var body: some View {
        let down = configuration.isPressed
        configuration.label
            .foregroundStyle(style.foreground)
            .frame(width: style.size, height: style.size)
            .background(Circle().fill(down ? style.pressedFill : style.fill))
            .contentShape(Circle())
            .scaleEffect(down ? 0.9 : 1)
            .animation(down ? .spring(response: 0.16, dampingFraction: 0.8) : .spring(response: 0.38, dampingFraction: 0.5), value: down)
            .onChange(of: down) { _, isDown in
                if isDown, style.haptics { Haptics.play(.tap) }
            }
    }
}

/// Text keys such as Delete: dims under the finger, one tap per press.
private struct TextKeyStyle: ButtonStyle {
    var haptics = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .onChange(of: configuration.isPressed) { _, isDown in
                if isDown, haptics { Haptics.play(.tap) }
            }
    }
}

/// The Face ID key. A tap runs Face ID; holding it for three seconds asks
/// to start over. After a moment of holding a thin red ring starts to draw
/// round the key so the hold can be seen, and it lets go without a tap.
/// Built on a drag gesture rather than a Button so a long hold never also
/// counts as a tap.
private struct FaceIDKey: View {
    var size: CGFloat
    var haptics: Bool
    var onTap: () -> Void
    var onHold: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var touching = false
    @State private var pressed = false
    @State private var cancelled = false
    @State private var held = false
    @State private var ring: CGFloat = 0
    @State private var hold: Task<Void, Never>?

    var body: some View {
        Image(systemName: "faceid")
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(Theme.primary)
            .frame(width: size, height: size)
            .background(Circle().fill(pressed ? Color(white: 0.22) : Theme.raised))
            .overlay {
                Circle()
                    .inset(by: 1.5)
                    .trim(from: 0, to: ring)
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(pressed ? .spring(response: 0.16, dampingFraction: 0.8) : .spring(response: 0.38, dampingFraction: 0.5), value: pressed)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        if far(value.translation) {
                            if !cancelled { cancelled = true; release() }
                            return
                        }
                        if !pressed, !cancelled { begin() }
                    }
                    .onEnded { value in
                        let tap = isEnabled && !held && !far(value.translation)
                        release()
                        cancelled = false
                        if tap { onTap() }
                    }
            )
            // Covers a touch the system takes away, as when a sheet appears.
            .onChange(of: touching) { _, now in
                if !now { release(); cancelled = false }
            }
            .accessibilityElement()
            .accessibilityLabel("Face ID")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityIdentifier("entry.key.faceid")
    }

    private func far(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) > size * 0.7
    }

    private func begin() {
        guard isEnabled else { return }
        pressed = true
        held = false
        if haptics { Haptics.play(.tap) }
        hold?.cancel()
        hold = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled, pressed else { return }
            if haptics { Haptics.play(.soft) }
            withAnimation(.linear(duration: 2.4)) { ring = 1 }
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, pressed else { return }
            held = true
            if haptics { Haptics.play(.warning) }
            onHold()
        }
    }

    private func release() {
        pressed = false
        hold?.cancel()
        hold = nil
        if ring > 0 { withAnimation(.smooth(duration: 0.25)) { ring = 0 } }
    }
}

// MARK: - Password

struct PasswordField: View {
    @Binding var text: String
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            SecureField("Password", text: $text, prompt: Text("Password").foregroundStyle(Theme.tertiary))
                .font(.title3.weight(.medium))
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .onSubmit(onSubmit)
                .focused($focused)
                .accessibilityIdentifier("entry.password")
            Button(action: onSubmit) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(PressableButtonStyle(scale: 0.88))
            .opacity(text.isEmpty ? 0.3 : 1)
            .disabled(text.isEmpty)
            .animation(Theme.snappy, value: text.isEmpty)
            .accessibilityLabel("Go")
            .accessibilityIdentifier("entry.password.go")
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .frame(height: 58)
        .background(Capsule().fill(Theme.raised))
        .overlay(Capsule().strokeBorder(focused ? Color.white.opacity(0.22) : Theme.hairline))
        .animation(Theme.snappy, value: focused)
        .frame(maxWidth: 340)
        .onAppear { focused = true }
    }
}

// MARK: - Start over

/// Reached by holding the Face ID key. Erases every space after ERASE is
/// typed; the way back when no code opens anything any more.
struct StartOverSheet: View {
    var haptics: Bool
    var onErase: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.raised))
                .padding(.bottom, 20)
            Text("Start over?")
                .font(.casitaTitle)
                .tracking(-0.6)
            Text("This erases every space on this iPhone. Backups in iCloud Drive stay. Type ERASE to confirm.")
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            TextField("", text: $text, prompt: Text("ERASE").foregroundStyle(Theme.tertiary))
                .font(.title3.weight(.semibold).monospaced())
                .tracking(4)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .focused($focused)
                .frame(height: 58)
                .background(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous).fill(Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .strokeBorder(text == "ERASE" ? Theme.danger.opacity(0.7) : Theme.hairline))
                .padding(.top, 24)
                .accessibilityIdentifier("entry.startOver.field")
            Spacer(minLength: 24)
            Button("Erase everything") {
                if haptics { Haptics.play(.thud) }
                dismiss()
                onErase()
            }
            .buttonStyle(RaisedButtonStyle(destructive: true))
            .disabled(text != "ERASE")
            .accessibilityIdentifier("entry.startOver.erase")
            Button("Cancel") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 6)
                .accessibilityIdentifier("entry.startOver.cancel")
        }
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Theme.primary)
        .background(Theme.background.ignoresSafeArea())
        .presentationBackground(Theme.background)
        .preferredColorScheme(.dark)
        .onChange(of: text == "ERASE") { _, ready in if ready, haptics { Haptics.play(.warning) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entry.startOver.screen")
    }
}
