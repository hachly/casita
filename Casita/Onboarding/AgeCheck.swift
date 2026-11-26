@preconcurrency import DeclaredAgeRange
import Synchronization
import SwiftUI

/// Apple's age range check, run only where the law asks for it. Apple decides
/// that from the Apple Account; Casita never looks at the IP address or
/// location. The results are app-wide, the same for every space.
enum AgeCheck {
    static let under18Key = "age.under18"
    static let adultKey = "age.adult"

    enum Outcome: Equatable, Sendable { case adult, under18, notShared }

    /// What an age range shared for the 18 gate means.
    static func outcome(lowerBound: Int?, upperBound: Int?) -> Outcome {
        if let lowerBound, lowerBound >= 18 { return .adult }
        if let upperBound, upperBound < 18 { return .under18 }
        return .notShared
    }

    static func outcome(_ response: AgeRangeService.Response) -> Outcome {
        switch response {
        case .declinedSharing: .notShared
        case .sharing(let range): outcome(lowerBound: range.lowerBound, upperBound: range.upperBound)
        @unknown default: .notShared
        }
    }

    /// How long Apple's age service gets to answer. In the simulator it never does.
    static let timeout: Duration = .seconds(4)

    /// Whether local law asks Casita to check age on this Apple Account.
    /// No answer in time, or an error, counts as no. `-forceAgeCheck`
    /// (debug builds) shows the step anyway.
    static func isRequired() async -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-forceAgeCheck") { return true }
        #endif
        guard #available(iOS 26.2, *) else { return false }
        return await firstOf(timeout, fallback: false) {
            (try? await AgeRangeService.shared.isEligibleForAgeFeatures) ?? false
        }
    }

    /// `operation`'s result, or `fallback` once `timeout` passes. Nothing
    /// waits for an operation that ignores cancellation.
    static func firstOf<T: Sendable>(_ timeout: Duration, fallback: T, _ operation: @escaping @Sendable () async -> T) async -> T {
        let once = Once<T>()
        return await withCheckedContinuation { continuation in
            once.set(continuation)
            Task { once.resume(await operation()) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(fallback)
            }
        }
    }

    private final class Once<T: Sendable>: Sendable {
        private let continuation = Mutex<CheckedContinuation<T, Never>?>(nil)
        func set(_ new: CheckedContinuation<T, Never>) { continuation.withLock { $0 = new } }
        func resume(_ value: T) {
            continuation.withLock { $0?.resume(returning: value); $0 = nil }
        }
    }

    static var confirmedAdult: Bool { UserDefaults.standard.bool(forKey: adultKey) }

    static func record(_ outcome: Outcome) {
        UserDefaults.standard.set(outcome == .under18, forKey: under18Key)
        if outcome == .adult { UserDefaults.standard.set(true, forKey: adultKey) }
    }
}

/// Step 10: asks Apple for the age range with an 18 gate.
struct AgeCheckView: View {
    var onPassed: () -> Void
    @Environment(\.requestAgeRange) private var requestAgeRange
    @AppStorage(AgeCheck.under18Key) private var under18 = false
    @State private var state: CheckState = .ask

    private enum CheckState { case ask, checking, notShared, failed }

    var body: some View {
        if under18 {
            // "Check again" on the stop screen can clear it.
            AgeStopView()
                .onDisappear { if AgeCheck.confirmedAdult { onPassed() } }
        } else {
            OnboardingPage(
                id: "onboarding.age",
                lead: "Casita is for adults.",
                title: "Share your age range.",
                text: "The law where you live asks apps to check that you're 18 or over.",
                primary: state == .checking ? "Checking…" : (state == .ask ? "Continue" : "Share age range"),
                primaryDisabled: state == .checking,
                primaryID: "onboarding.age.continue",
                action: { Task { await check() } },
                secondary: state == .failed ? PageAction("Continue anyway", id: "onboarding.age.anyway", action: onPassed) : nil,
                artHeight: 140
            ) {
                AgeBadge(checking: state == .checking)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } content: {
                VStack(spacing: 12) {
                    Text("Apple shares only an age range, never your birthday.")
                        .foregroundStyle(Theme.secondary)
                    switch state {
                    case .notShared: Text("Casita can't continue without your age range.").fontWeight(.semibold)
                    case .failed: Text("The age check didn't work this time.").fontWeight(.semibold)
                    default: EmptyView()
                    }
                }
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .animation(Theme.smooth, value: state)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding.age.detail")
            }
        }
    }

    private func check() async {
        state = .checking
        let request = requestAgeRange
        // A system sheet asks the person, so this waits much longer.
        let response = await AgeCheck.firstOf(.seconds(60), fallback: nil) {
            try? await request(ageGates: 18)
        }
        guard let response else {
            state = .failed
            Haptics.play(.warning)
            return
        }
        let outcome = AgeCheck.outcome(response)
        AgeCheck.record(outcome)
        switch outcome {
        case .adult:
            Haptics.play(.success)
            onPassed()
        case .under18:
            state = .ask
        case .notShared:
            state = .notShared
            Haptics.play(.warning)
        }
    }
}

/// "18+" in a ring that draws itself; the ring breathes while Apple answers.
private struct AgeBadge: View {
    var checking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.8), value: drawn)
            Text("18+")
                .font(.system(size: 30, weight: .heavy))
                .monospacedDigit()
                .opacity(drawn || reduceMotion ? 1 : 0)
                .scaleEffect(drawn || reduceMotion ? 1 : 0.7)
                .animation(Theme.bouncy.delay(0.45), value: drawn)
        }
        .frame(width: 104, height: 104)
        .phaseAnimator([false, true], trigger: checking) { view, phase in
            view.scaleEffect(checking && phase && !reduceMotion ? 0.94 : 1)
        } animation: { _ in .easeInOut(duration: 0.5) }
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            drawn = true
            try? await Task.sleep(for: .milliseconds(650))
            if !reduceMotion { Haptics.play(.soft) }
        }
        .accessibilityHidden(true)
    }
}

/// Shown instead of everything else once Apple says the person is under 18,
/// on every launch until a new check says otherwise.
struct AgeStopView: View {
    @Environment(\.requestAgeRange) private var requestAgeRange
    @State private var checking = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            TwoToneTitle(lead: "Casita is for adults.", key: "It stops here.", font: .casitaTitle, alignment: .center)
            Text("Your Apple Account says you're under 18, so Casita stops here. Nothing you added has left this iPhone.")
                .fixedSize(horizontal: false, vertical: true)
            Text("To give back the storage Casita set aside, delete the app.")
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(checking ? "Checking…" : "Check again") {
                checking = true
                Task {
                    if let response = try? await requestAgeRange(ageGates: 18) {
                        AgeCheck.record(AgeCheck.outcome(response))
                    }
                    checking = false
                }
            }
            .buttonStyle(RaisedButtonStyle())
            .disabled(checking)
            .accessibilityIdentifier("onboarding.age.recheck")
        }
        .multilineTextAlignment(.center)
        .padding(Theme.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.age.stop")
    }
}
