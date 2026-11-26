import LocalAuthentication
import Observation
import SwiftUI

/// The onboarding steps, in order.
enum OnboardingStep: Int, CaseIterable, Sendable {
    /// 1. Marketing screens.
    case welcome
    /// 2. Everyday code and Face ID.
    case everydayCode
    /// 3. Private code; it will open the top space. Its Continue makes the storage.
    case privateCode
    /// 4. The recovery sentence. Backups and the reset switch are asked
    /// later, inside a space.
    case recoveryKey
    /// 5. Photos, files and accounts for the everyday space, if the person wants.
    case fillEveryday
    /// 6. Age check, only where the law asks for it.
    case ageCheck
    /// 7. Paywall. The last step: a plan opens the everyday space. No rating
    /// request in setup (App Store guideline 5.6.3); `RatingPrompt` asks
    /// later, after real use.
    case paywall

    /// The same step in the setup funnel RevenueCat sees; the welcome pages
    /// report their own.
    var funnel: SetupFunnel.Step? {
        switch self {
        case .welcome: nil
        case .everydayCode: .everydayCode
        case .privateCode: .privateCode
        case .recoveryKey: .recoveryWords
        case .fillEveryday: .fill
        case .ageCheck: .ageCheck
        case .paywall: .paywallTrial
        }
    }

    /// The step after this one; nil after the last.
    func next(ageCheckRequired: Bool) -> OnboardingStep? {
        var candidate = OnboardingStep(rawValue: rawValue + 1)
        if candidate == .ageCheck, !ageCheckRequired { candidate = .paywall }
        return candidate
    }

    /// Only the steps before the storage exists can go back. Once it is made
    /// the flow moves forward only, and a relaunch goes to the entry screen.
    var previous: OnboardingStep? {
        switch self {
        case .everydayCode: .welcome
        case .privateCode: .everydayCode
        default: nil
        }
    }

    /// True from the moment the storage exists: it is made when the
    /// private code's Continue is tapped.
    var storageExists: Bool { rawValue > OnboardingStep.privateCode.rawValue }
}

/// What onboarding has collected so far. Codes live only here, in memory,
/// until the storage is made; nothing about them is written anywhere else.
@MainActor @Observable
final class OnboardingModel {
    private(set) var step: OnboardingStep = .welcome
    /// Which way the last move went, so the screens slide the right way.
    private(set) var movedForward = true
    var everydayCode: String?
    var privateCode: String?
    var useFaceID = OnboardingModel.biometricsAvailable
    var spaces: AppModel.FirstSpaces?
    /// Looked up early so the step after the small-team page is known in time.
    private var ageCheckRequired: Bool?
    private var ageLookup: Task<Bool, Never>?

    static var biometricsAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Sets aside 512 MB and makes both spaces, with no page of its own.
    /// Nil when it worked, otherwise why not.
    func createSpaces(app: AppModel) async -> String? {
        guard spaces == nil else { return nil }
        guard let everyday = everydayCode, let privateCode else { return nil }
        guard !StoragePlan.sizes(available: StoragePlan.availableBytes()).isEmpty else {
            return "Casita needs \(StoragePlan.label(bytes: StorageSize.mb512.rawValue + StoragePlan.headroom)) free on this iPhone."
        }
        do {
            spaces = try await app.createFirstSpaces(
                privateCode: privateCode, everydayCode: everyday,
                useFaceID: useFaceID && Self.biometricsAvailable, size: .mb512
            )
            return nil
        } catch FirstRunError.storageExists {
            return "Casita already has storage on this iPhone. Close Casita and open it again."
        } catch {
            return "Casita couldn't set the storage aside. Free up space on this iPhone."
        }
    }

    func startAgeLookup() {
        guard ageLookup == nil else { return }
        ageLookup = Task { await AgeCheck.isRequired() }
    }

    func advance() async {
        if step == .fillEveryday, ageCheckRequired == nil {
            startAgeLookup()
            ageCheckRequired = await ageLookup?.value ?? false
        }
        if let next = step.next(ageCheckRequired: ageCheckRequired ?? false) {
            movedForward = true
            step = next
        }
    }

    func back() {
        guard let previous = step.previous else { return }
        switch step {
        case .everydayCode: everydayCode = nil
        case .privateCode: privateCode = nil
        default: break
        }
        movedForward = false
        step = previous
    }
}

/// First run: the 11 onboarding steps, then the "Open Casita faster" tip,
/// then the entry screen. Each step slides in the way the person is going;
/// a thin line at the top shows how far through setup they are.
struct OnboardingFlow: View {
    @Environment(AppModel.self) private var app
    @State private var flow = OnboardingModel()
    @State private var restoring = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.background.ignoresSafeArea()
                content
                    .id(flow.step)
                    .transition(reduceMotion ? .opacity : .onboardingStep(forward: flow.movedForward))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .top) { setupProgress(compact: geometry.size.height < 700) }
            .environment(\.onboardingCompact, geometry.size.height < 700)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(.white)
        .animation(Theme.smooth, value: flow.step)
        .fullScreenCover(isPresented: $restoring) {
            RestoreFlow(onCancel: { restoring = false })
        }
        .onChange(of: flow.step, initial: true) { _, step in step.funnel.map { SetupFunnel.reached($0) } }
        .task {
            // A relaunch after the storage exists goes to the entry screen
            // from AppModel.start; this only guards against arriving here
            // with storage already open.
            if app.storage != nil, flow.spaces == nil { app.finishFirstRun() }
            // A build cut short last time; give its space back before the
            // storage step measures free space.
            if app.storage == nil { try? FileManager.default.removeItem(at: AppModel.partialStorageURL) }
            flow.startAgeLookup()
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .welcome:
            WelcomePages(onDone: next, onRestore: { restoring = true }, startAtEnd: !flow.movedForward)
        case .everydayCode:
            CodeSetupStep(kind: .everyday, flow: flow, onDone: next, onBack: flow.back)
        case .privateCode:
            CodeSetupStep(kind: .private, flow: flow, onDone: next, onBack: flow.back)
        case .recoveryKey:
            if let spaces = flow.spaces, let storage = app.storage {
                RecoveryStep(storage: storage, top: spaces.top, onDone: next)
            }
        case .fillEveryday:
            if let spaces = flow.spaces, let storage = app.storage {
                FillEverydayStep(storage: storage, everyday: spaces.everyday, onDone: next)
            }
        case .ageCheck:
            AgeCheckView(onPassed: next)
        case .paywall:
            // Straight into the everyday space: setup just typed its code.
            PaywallView(onClose: {
                SetupFunnel.reached(.done)
                app.finishFirstRun(opening: flow.spaces?.everyday)
            }, onboarding: true)
        }
    }

    /// From the everyday code to the age check; hidden on the welcome
    /// pages and the paywall.
    private func setupProgress(compact: Bool) -> some View {
        let first = OnboardingStep.everydayCode.rawValue
        let last = OnboardingStep.ageCheck.rawValue
        let shown = (first...last).contains(flow.step.rawValue)
        let value = Double(flow.step.rawValue - first + 1) / Double(last - first + 1)
        return ProgressLine(value: shown ? value : 0)
            .frame(width: 88)
            .padding(.top, compact ? 18 : 20)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Setup progress")
            .accessibilityValue("\(Int((value * 100).rounded())) percent")
            .accessibilityIdentifier("onboarding.progress")
    }

    private func next() {
        Task { await flow.advance() }
    }
}
