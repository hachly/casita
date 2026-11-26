import CoreHaptics
import UIKit

/// Every vibration Casita makes, named for what it means. All of them follow
/// the app-wide Haptics switch, which is the same for every space.
@MainActor
enum Haptics {
    enum Kind {
        /// A key, a button, a dot joined.
        case tap
        /// A choice changed: segment, plan, slider stop.
        case select
        /// Something arrives on screen.
        case soft
        /// A heavier landing, such as the logo settling.
        case thud
        case success, warning, error
        /// The logo's wink: two quick light taps.
        case wink
        /// A space opens: a soft swell then a crisp click.
        case unlock
        /// A slow double beat for waiting or for a reveal.
        case heartbeat
    }

    /// Overridden by onboarding before the storage (and its setting) exists.
    static var enabled: Bool { LockSettingsStore.standard.load().haptics }

    static func play(_ kind: Kind) {
        guard enabled else { return }
        switch kind {
        case .tap: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .select: UISelectionFeedbackGenerator().selectionChanged()
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .thud: UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .wink: pattern([(0, 0.55, 0.9), (0.09, 0.4, 0.9)])
        case .unlock: pattern([(0, 0.35, 0.2), (0.06, 0.5, 0.3), (0.14, 1.0, 0.95)])
        case .heartbeat: pattern([(0, 0.7, 0.35), (0.16, 0.45, 0.3)])
        }
    }

    /// Plays transient taps of (time, intensity, sharpness). Falls back to a
    /// light impact where Core Haptics isn't available, as in the simulator.
    private static func pattern(_ taps: [(TimeInterval, Float, Float)]) {
        guard let engine = engine else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        let events = taps.map { time, intensity, sharpness in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: time)
        }
        do {
            try engine.start()
            try engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private static let engine: CHHapticEngine? = {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, let engine = try? CHHapticEngine() else { return nil }
        // No reset handler (it runs off the main actor); every
        // play calls start(), which brings a stopped or reset engine back.
        engine.isAutoShutdownEnabled = true
        return engine
    }()
}
