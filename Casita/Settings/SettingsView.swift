import SwiftUI
import UIKit

/// Settings, reached from every space. The screen is the same in every
/// space: the same rows, the same words, app-wide values. The only values
/// about the open space are its free room and its reset switch, and neither
/// says which space it is or whether any space is above it.
struct SettingsView: View {
    let space: SpaceRef
    @Environment(AppModel.self) private var model

    var body: some View {
        if let storage = model.storage {
            SettingsScreen(space: space, settings: SettingsModel(storage: storage))
        }
    }
}

private struct SettingsScreen: View {
    let space: SpaceRef
    @State private var settings: SettingsModel
    @Environment(AppModel.self) private var model
    @Environment(Entitlements.self) private var entitlements
    @State private var showPaywall = false
    @State private var paywallReason: PlanLimit = .storage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// About the open space; loaded each time the screen appears.
    @State private var freeRoom: Int64?
    @State private var resetOn = false

    @State private var sheet: SettingsSheet?
    /// Shown once the sheet in front has gone, so two never overlap.
    @State private var next: SettingsSheet?
    @State private var toast: String?
    @State private var appeared = false
    @State private var confirmRestart = false

    init(space: SpaceRef, settings: SettingsModel) {
        self.space = space
        _settings = State(initialValue: settings)
    }

    var body: some View {
        @Bindable var app = model
        let shown = appeared || reduceMotion
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                ScreenHeader(title: "Settings")
                SettingsGroup(title: "Locking", footer: "Casita also locks when you leave it. Reopening needs the same space's code.") {
                    SettingsChoiceRow(
                        glyph: .lock, title: "Lock after", options: LockSettings.idleChoices,
                        selection: app.lockSettings.idleSeconds, label: Self.idleLabel,
                        identifier: "settings.lockAfter", optionName: { "\($0)" },
                        onSelect: { app.lockSettings.idleSeconds = $0 }
                    )
                    SettingsChoiceRow(
                        symbol: "iphone.gen3", title: "Quick lock", options: LockSettings.Gesture.allCases,
                        selection: app.lockSettings.gesture, label: Self.gestureLabel,
                        identifier: "settings.quickLock", optionName: \.rawValue,
                        onSelect: { app.lockSettings.gesture = $0 }
                    )
                    SettingsChoiceRow(
                        symbol: "arrow.uturn.backward", title: "Reopen where I was", options: LockSettings.reopenChoices,
                        selection: app.lockSettings.reopenMinutes, label: Self.reopenLabel,
                        identifier: "settings.reopen", optionName: { "\($0)" },
                        onSelect: { app.lockSettings.reopenMinutes = $0 }
                    )
                    SettingsSwitchRow(symbol: "eye.slash", title: "Dots: hide the line", isOn: $app.lockSettings.hideDotsLine)
                        .accessibilityIdentifier("settings.hideDotsLine")
                    SettingsSwitchRow(symbol: "waveform", title: "Haptics", isOn: $app.lockSettings.haptics)
                        .accessibilityIdentifier("settings.haptics")
                    // Only a phone that folds (iPhone Duo) can be closed.
                    if app.hasHinge {
                        SettingsSwitchRow(symbol: "book.closed", title: "Lock when closed", isOn: $app.lockSettings.lockWhenClosed)
                            .accessibilityIdentifier("settings.lockWhenClosed")
                    }
                }
                .reveal(0, active: shown)

                SettingsGroup(title: "Storage", footer: "No space sees all of it as free. It can grow, never shrink.") {
                    SettingsValueRow(symbol: "internaldrive", title: "Reserved storage", value: reservedLabel ?? " ")
                        .accessibilityIdentifier("settings.reservedStorage")
                    SettingsValueRow(glyph: .house, title: "Free in this space",
                                     value: freeRoom.map { $0.formatted(.byteCount(style: .memory)) } ?? " ")
                        .accessibilityIdentifier("settings.freeRoom")
                    growRow
                }
                .reveal(1, active: shown)

                SettingsGroup(title: "Backup", footer: "Automatic backups use Wi-Fi while charging. The previous copy stays until the new one uploads, temporarily using up to twice the reserved storage in iCloud.") {
                    SettingsChoiceRow(
                        glyph: .cloud, title: "Back up to iCloud", options: BackupSchedule.allCases,
                        selection: settings.schedule, label: \.label,
                        identifier: "settings.backupSchedule", optionName: \.rawValue,
                        onSelect: { schedule in
                            guard schedule == .off || entitlements.allows(.automaticBackup) else {
                                paywallReason = .automaticBackup; showPaywall = true; return
                            }
                            settings.setSchedule(schedule)
                        }
                    )
                    SettingsValueRow(symbol: "clock", title: "Last uploaded backup",
                                     value: settings.backup.lastVerifiedUpload.map(Self.dateLabel) ?? "Not confirmed")
                        .accessibilityIdentifier("settings.lastBackup")
                    if !entitlements.isSubscribed, settings.schedule != .off {
                        Text("Automatic backups are paused on Free. You can still export a backup below.")
                            .font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    if settings.backup.pendingFingerprint != nil {
                        Text("Waiting for iCloud to finish uploading.")
                            .font(.footnote).foregroundStyle(Theme.secondary)
                            .accessibilityIdentifier("settings.backupPending")
                    }
                    SettingsValueRow(symbol: "square.and.arrow.up", title: "Last exported backup",
                        value: settings.backup.lastExport.map(Self.dateLabel) ?? "Never")
                    if let failure = settings.backup.lastFailure {
                        CasitaRow(symbol: "exclamationmark.triangle", title: "Last problem",
                                  detail: settings.backup.lastFailureMessage, tint: Theme.danger) {
                            Text(Self.dateLabel(failure))
                                .font(.footnote)
                                .foregroundStyle(Theme.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.lastProblem")
                    }
                    BackupExportButton(storage: settings.storage, onExport: { Task { await reload() } })
                        .buttonStyle(RowButtonStyle(symbol: "square.and.arrow.up"))
                        .accessibilityIdentifier("settings.backupNow")
                }
                .reveal(2, active: shown)

                SettingsGroup(title: "Recovery sentence", footer: "A new sentence covers this space and the ones under it. With the switch on, your sentence can set a new code here.") {
                    Button {
                        Haptics.play(.warning)
                        sheet = .confirmNewKey
                    } label: {
                        CasitaRow(glyph: .key, title: "New recovery sentence", tint: Theme.gold)
                    }
                    .buttonStyle(RowPressStyle())
                    .accessibilityIdentifier("settings.newRecoveryKey")
                    SettingsSwitchRow(glyph: .shield, title: "Let my sentence reset this space's code",
                                      onTint: Theme.gold, isOn: resetOn) { on in
                        if on {
                            Haptics.play(.warning)
                            sheet = .confirmReset
                        } else {
                            setReset(false)
                        }
                    }
                    .accessibilityIdentifier("settings.resetWithWords")
                }
                .reveal(3, active: shown)

                SettingsGroup(title: "This space", footer: "Deleting this space also deletes every space under it.") {
                    Button { sheet = .changeCode } label: {
                        CasitaRow(glyph: .lock, title: "Change this space's code")
                    }
                    .buttonStyle(RowPressStyle())
                    .accessibilityIdentifier("settings.changeCode")
                    Button { sheet = .delete } label: {
                        CasitaRow(symbol: "trash", title: "Delete this space", tint: Theme.danger)
                    }
                    .buttonStyle(RowPressStyle())
                    .accessibilityIdentifier("settings.deleteSpace")
                }
                .reveal(4, active: shown)

                SettingsGroup(title: nil, footer: nil) {
                    NavigationLink { OpenFasterGuide() } label: {
                        CasitaRow(symbol: "bolt", title: "Open Casita faster", detail: "Action Button, Lock Screen, Focus")
                    }
                    .buttonStyle(RowPressStyle())
                    .accessibilityIdentifier("settings.openFaster")
                    NavigationLink { PrivacyView() } label: {
                        CasitaRow(glyph: .shield, title: "Privacy", detail: "What stays here, what leaves")
                    }
                    .buttonStyle(RowPressStyle())
                    .accessibilityIdentifier("settings.privacy")
                    Link(destination: StoreLinks.terms) {
                        CasitaRow(symbol: "doc.text", title: "Terms of use")
                    }
                    .buttonStyle(RowPressStyle())
                    .accessibilityIdentifier("settings.terms")
                }
                .reveal(5, active: shown)
                #if DEBUG || TESTER
                // Test builds only: the App Store build never has this row.
                SettingsGroup(title: "Testing", footer: Self.restartFooter) {
                    Button {
                        Haptics.play(.warning)
                        confirmRestart = true
                    } label: {
                        CasitaRow(symbol: "arrow.counterclockwise", title: "Restart setup", tint: Theme.danger)
                    }
                    .buttonStyle(RowPressStyle())
                    .accessibilityIdentifier("settings.restartSetup")
                }
                .alert("Erase everything and restart setup?", isPresented: $confirmRestart) {
                    Button("Erase and restart", role: .destructive) {
                        model.startOver()
                        #if DEBUG
                        // A new RevenueCat customer, so the paywall offers the trial again.
                        RevenueCatConfig.startFreshCustomer()
                        UserDefaults.standard.removeObject(forKey: SetupFunnel.furthestKey)
                        Entitlements.shared.restart()
                        #endif
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every space and everything in it is erased. This can't be undone.")
                }
                #endif
                Text("Casita \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))\(testerTag)")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .collapsingTitle("Settings")
        .disabled(settings.growing)
        .task { await reload() }
        .onAppear { appeared = true }
        .barToast($toast)
        .sheet(item: $sheet, onDismiss: sheetGone) { sheet in
            Group {
                switch sheet {
                case .changeCode:
                    ChangeCodeSheet(space: space, settings: settings) { toast = "Code changed" }
                case .delete:
                    DeleteThisSpaceSheet(space: space, settings: settings)
                case .recoveryKey(let phrase):
                    NewRecoveryKeySheet(phrase: phrase, space: space, settings: settings) {
                        next = .notice(Notice(title: "New recovery sentence saved", message: "Backups from now on open with the new sentence.",
                                              symbol: "checkmark", tint: Theme.gold))
                    }
                case .confirmGrow:
                    PromptSheet(symbol: "plus.square.on.square", title: "Make more room?", message: growMessage,
                                confirmTitle: settings.nextSize.map { "Grow to \($0.label)" } ?? "Grow",
                                identifier: "settings.grow") { grow() }
                case .confirmReset:
                    PromptSheet(glyph: .shield, tint: Theme.gold, title: "Let the sentence reset your code?",
                                message: "Your recovery sentence becomes a master key. Anyone who has them can set a new code for this space and open it, and every space under it.",
                                confirmTitle: "Turn on", identifier: "settings.reset") { setReset(true) }
                case .confirmNewKey:
                    PromptSheet(glyph: .key, tint: Theme.gold, title: "Make a new recovery sentence?",
                                message: "You'll get a new sentence. It covers this space and the spaces under it, and the sentence you have now stops working for them.",
                                confirmTitle: "Show new sentence", identifier: "settings.newKey") {
                        // The sentence comes up once this sheet has gone.
                        next = .recoveryKey(RecoveryPhrase())
                    }
                case .notice(let notice):
                    PromptSheet(symbol: notice.symbol, tint: notice.tint, title: notice.title, message: notice.message,
                                confirmTitle: "OK", cancelTitle: nil, identifier: "settings.notice") {}
                }
            }
            .coverWhenInactive()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.screen")
        .holdsIdleLock(settings.growing)
        .paywall(isPresented: $showPaywall, reason: paywallReason)
    }

    // MARK: Storage

    @ViewBuilder private var growRow: some View {
        if settings.growing {
            CasitaRow(symbol: "plus.square.on.square", title: "Making room…", detail: "Keep Casita open.") {
                ProgressView().tint(.white)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.makeMoreRoom")
        } else if let next = settings.nextSize {
            Button { askToGrow() } label: {
                CasitaRow(symbol: "plus.square.on.square", title: "Make more room", detail: "Grow to \(next.label)")
            }
            .buttonStyle(RowPressStyle())
            .accessibilityIdentifier("settings.makeMoreRoom")
        } else {
            CasitaRow(symbol: "plus.square.on.square", title: "Already at the largest size", tint: Theme.secondary, chevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.makeMoreRoom")
        }
    }

    /// nil until the first refresh has read the size.
    private var reservedLabel: String? {
        settings.reservedBytes > 0 ? SettingsModel.sizeLabel(settings.reservedBytes) : nil
    }

    private func reload() async {
        await settings.refresh()
        freeRoom = await settings.freeRoom(in: space)
        resetOn = await settings.resetIsOn(in: space)
    }

    private func sheetGone() {
        Task { await reload() }
        if sheet == nil, let waiting = next {
            next = nil
            sheet = waiting
        }
    }

    private var growMessage: String {
        guard let next = settings.nextSize else { return "" }
        let now = SettingsModel.sizeLabel(settings.reservedBytes)
        let extra = (next.rawValue - settings.reservedBytes).formatted(.byteCount(style: .memory))
        return "Grows from \(now) to \(next.label), taking \(extra) more from this iPhone. It can't shrink later."
    }

    private func askToGrow() {
        guard entitlements.allows(.growStorage) else { paywallReason = .storage; showPaywall = true; return }
        guard let next = settings.nextSize else { return }
        if settings.iPhoneHasRoomToGrow {
            sheet = .confirmGrow
        } else {
            let needed = (next.rawValue - settings.reservedBytes + SettingsModel.iPhoneMargin).formatted(.byteCount(style: .memory))
            Haptics.play(.warning)
            sheet = .notice(Notice(title: "Not enough space on this iPhone", message: "Growing to \(next.label) needs about \(needed) free on the iPhone.", symbol: "internaldrive"))
        }
    }

    private func grow() {
        // Keep the iPhone awake and give the write time to finish if Casita
        // leaves the screen, so the file is never left half grown.
        UIApplication.shared.isIdleTimerDisabled = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "Make more room")
        Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.endBackgroundTask(background)
            }
            do {
                try await settings.makeMoreRoom(for: space)
                freeRoom = await settings.freeRoom(in: space)
                Haptics.play(.success)
                toast = "More room in this space"
            } catch {
                Haptics.play(.error)
                show(Notice(title: "Couldn't make more room", message: "Nothing in your spaces changed."))
            }
        }
    }

    private func setReset(_ on: Bool) {
        Task {
            do {
                try await settings.setReset(on, for: space)
            } catch {
                Haptics.play(.error)
                show(Notice(title: "Couldn't change the reset switch"))
            }
            resetOn = await settings.resetIsOn(in: space)
        }
    }

    /// Shows a notice now, or once the sheet in front has gone.
    private func show(_ notice: Notice) {
        if sheet == nil { sheet = .notice(notice) } else { next = .notice(notice) }
    }

    /// "Off", "1 min", "5 min", "15 min".
    static func reopenLabel(_ minutes: Int) -> String {
        minutes == 0 ? "Off" : "\(minutes) min"
    }

    #if DEBUG
    static let restartFooter = "Erases every space, Face ID and the waits, and starts a new RevenueCat customer. Then setup starts again."
    #else
    static let restartFooter = "Erases every space, Face ID and the waits. Then setup starts again."
    #endif

    static func idleLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
    }

    static func gestureLabel(_ gesture: LockSettings.Gesture) -> String {
        switch gesture {
        case .flip: "Flip face down"
        case .twoFingerDoubleTap: "Two-finger double tap"
        case .off: "Off"
        }
    }

    static func dateLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private enum SettingsSheet: Identifiable {
    case changeCode, delete, recoveryKey(RecoveryPhrase)
    case confirmGrow, confirmReset, confirmNewKey
    case notice(Notice)

    var id: String {
        switch self {
        case .changeCode: "changeCode"
        case .delete: "delete"
        case .recoveryKey: "recoveryKey"
        case .confirmGrow: "confirmGrow"
        case .confirmReset: "confirmReset"
        case .confirmNewKey: "confirmNewKey"
        case .notice(let notice): "notice." + notice.title
        }
    }
}

private struct Notice {
    var title: String
    var message: String?
    var symbol = "exclamationmark.triangle"
    var tint = Theme.primary
}

/// Says so in Settings when this is a tester build (everything unlocked).
#if TESTER
private let testerTag = " · Tester build"
#else
private let testerTag = ""
#endif
