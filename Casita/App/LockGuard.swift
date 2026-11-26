import Combine
import CoreMotion
import SwiftUI
import UIKit

/// Locks Casita when it leaves the screen, after a while without touches,
/// and on the quick-lock gesture. Also covers the screen for the app
/// switcher snapshot and while the screen is being recorded or mirrored.
struct LockGuard: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isSceneCaptured) private var isCaptured
    @State private var lastTouch = Date.now
    @State private var motion = CMMotionManager()
    /// The keyboard draws outside Casita's window, so typing is never seen
    /// as a touch. While it is up the idle lock waits 5 minutes instead.
    @State private var keyboardUp = false
    @State private var flip = FlipDetector()

    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// Development only: the simulator panel streams the screen, which iOS
    /// reports as capture. `-ignoreCapture` keeps the app usable there.
    private var captured: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ignoreCapture") { return false }
        #endif
        return isCaptured
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase != .active || captured, initial: true) { _, covered in
                CoverWindow.show(covered)
            }
            .onChange(of: scenePhase) { _, phase in
                // Inactive only covers the screen: a purchase sheet, Face ID
                // prompt or Control Center must not lock the space. Leaving
                // the app (background) locks.
                if phase == .background { model.lock() }
            }
            .onChange(of: captured) { _, captured in
                if captured { model.lock() }
            }
            .onReceive(tick) { now in
                model.heartbeat()
                guard case .open = model.phase, model.idleHolds.isEmpty else { return }
                let limit = keyboardUp ? max(model.lockSettings.idleSeconds, 300) : model.lockSettings.idleSeconds
                if now.timeIntervalSince(lastTouch) >= Double(limit) { model.lock() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardUp = true
                lastTouch = .now
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboardUp = false
                lastTouch = .now
            }
            // The idle count starts over when a hold ends (an import finishing).
            .onChange(of: model.idleHolds) { lastTouch = .now }
            .onChange(of: model.phase) { _, phase in
                lastTouch = .now
                if case .open = phase { startGesture() } else { stopGesture() }
            }
            .background(WindowTouches(twoFingerDoubleTap: model.lockSettings.gesture == .twoFingerDoubleTap,
                                      onTouch: { lastTouch = .now }, onDoubleTap: { model.lock() }))
            .background(HingeWatch(onHinge: { model.hasHinge = $0 }, onClose: {
                if model.lockSettings.lockWhenClosed, case .open = model.phase { model.lock() }
            }))
    }

    private func startGesture() {
        guard model.lockSettings.gesture == .flip, motion.isDeviceMotionAvailable else { return }
        flip = FlipDetector()
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let data else { return }
            let a = data.userAcceleration, r = data.rotationRate
            let put = flip.sample(
                faceDown: data.gravity.z,
                shake: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot(),
                turn: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot(),
                at: .now, lastTouch: lastTouch
            )
            if put { Task { @MainActor in model.lock() } }
        }
    }

    private func stopGesture() {
        motion.stopDeviceMotionUpdates()
    }
}

/// The cover sits in its own window above everything Casita shows, sheets
/// and full-screen views included, which an overlay on the root view can't
/// reach. Only out-of-process screens (Face ID, a purchase sheet, Control
/// Center) make Casita inactive, and those draw above any app window.
@MainActor
private enum CoverWindow {
    static var window: UIWindow?

    static func show(_ shown: Bool) {
        if window == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = .alert + 1
            // The mark centres on the whole screen, not the safe area, which a
            // side bar (the iPhone Duo's) would pull off centre.
            let host = UIHostingController(rootView: ZStack {
                Theme.background
                CasitaMark(style: .onDark).frame(width: 64, height: 64).opacity(0.9)
            }.ignoresSafeArea())
            host.view.backgroundColor = .black
            cover.rootViewController = host
            window = cover
        }
        window?.isHidden = !shown
    }
}

/// Tells a phone put face down from one held face down overhead, say lying
/// in bed: the screen must face the floor almost flat, the phone must be as
/// still as on a table (a hand always trembles and turns a little), for a
/// whole second, with no touch in the last 2 s.
struct FlipDetector {
    static let faceDown = 0.95
    static let stillShake = 0.03
    static let stillTurn = 0.1
    static let hold: TimeInterval = 1
    static let sinceTouch: TimeInterval = 2

    private var downSince: Date?

    /// One motion sample: gravity's z (1 is screen to the floor), user
    /// acceleration in g, rotation in rad/s. True once it counts as put down.
    mutating func sample(faceDown: Double, shake: Double, turn: Double, at now: Date, lastTouch: Date) -> Bool {
        guard faceDown > Self.faceDown, shake < Self.stillShake, turn < Self.stillTurn,
              now.timeIntervalSince(lastTouch) > Self.sinceTouch else {
            downSince = nil
            return false
        }
        let since = downSince ?? now
        downSince = since
        return now.timeIntervalSince(since) >= Self.hold
    }
}

extension View {
    func lockGuard() -> some View { modifier(LockGuard()) }

    /// Keeps the idle lock away while `active` (see `AppModel.idleHolds`).
    func holdsIdleLock(_ active: Bool) -> some View { modifier(IdleHold(active: active)) }
}

private struct IdleHold: ViewModifier {
    var active: Bool
    @Environment(AppModel.self) private var model
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { hold(active) }
            .onChange(of: active) { _, now in hold(now) }
            .onDisappear { hold(false) }
    }

    private func hold(_ on: Bool) {
        if on { model.idleHolds.insert(token) } else { model.idleHolds.remove(token) }
    }
}

/// Watches the hinge of a foldable iPhone (iPhone Duo, iOS 27.1). Tells
/// whether there is one, and calls `onClose` when the phone goes from open
/// to closed. The first report is the phone as it already is, never a close.
private struct HingeWatch: UIViewRepresentable {
    var onHinge: (Bool) -> Void
    var onClose: () -> Void

    final class Coordinator {
        var onHinge: (Bool) -> Void = { _ in }
        var onClose: () -> Void = {}
        var wasOpen: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        if #available(iOS 27.1, *) {
            let coordinator = context.coordinator
            view.addInteraction(UIHingeInteraction { _, update in
                coordinator.onHinge(update.hinge != nil)
                guard let status = update.hinge?.status, status != .unknown else { return }
                let open = status != .closed
                if coordinator.wasOpen == true, !open { coordinator.onClose() }
                coordinator.wasOpen = open
            })
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onHinge = onHinge
        context.coordinator.onClose = onClose
    }
}

/// Window-level touch hooks that never block the touch itself: every touch
/// resets the idle timer, and an optional two-finger double tap locks.
private struct WindowTouches: UIViewRepresentable {
    var twoFingerDoubleTap: Bool
    var onTouch: () -> Void
    var onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTouch: onTouch, onDoubleTap: onDoubleTap) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTouch = onTouch
        coordinator.onDoubleTap = onDoubleTap
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Every window of the scene, so touches in full-screen views and
            // anything shown later count too.
            for each in window.windowScene?.windows ?? [window] { coordinator.watch(each) }
            if twoFingerDoubleTap, coordinator.recognizer == nil {
                let recognizer = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.fire))
                recognizer.numberOfTouchesRequired = 2
                recognizer.numberOfTapsRequired = 2
                recognizer.cancelsTouchesInView = false
                window.addGestureRecognizer(recognizer)
                coordinator.recognizer = recognizer
            } else if !twoFingerDoubleTap, let recognizer = coordinator.recognizer {
                window.removeGestureRecognizer(recognizer)
                coordinator.recognizer = nil
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTouch: () -> Void
        var onDoubleTap: () -> Void
        var recognizer: UITapGestureRecognizer?
        private var watched: Set<ObjectIdentifier> = []

        init(onTouch: @escaping () -> Void, onDoubleTap: @escaping () -> Void) {
            self.onTouch = onTouch
            self.onDoubleTap = onDoubleTap
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(windowShown(_:)), name: UIWindow.didBecomeVisibleNotification, object: nil)
        }

        func watch(_ window: UIWindow) {
            guard watched.insert(ObjectIdentifier(window)).inserted else { return }
            let observer = TouchObserver()
            observer.onTouch = { [weak self] in self?.onTouch() }
            observer.cancelsTouchesInView = false
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            window.addGestureRecognizer(observer)
        }

        @objc private func windowShown(_ note: Notification) {
            if let window = note.object as? UIWindow { watch(window) }
        }

        @objc func fire() { onDoubleTap() }
    }
}

/// Reports touches without ever claiming one: a touch going down, and a
/// finger still moving (at most once a second, so a long scroll counts).
/// It never recognizes anything, so nothing else is affected. Reports are
/// direct calls: UIKit sends no target-action for a recognizer that fails,
/// which is why the first version never reported a touch at all.
private final class TouchObserver: UIGestureRecognizer {
    var onTouch: () -> Void = {}
    private var lastReport = Date.distantPast

    private func report() {
        let now = Date.now
        guard now.timeIntervalSince(lastReport) >= 1 else { return }
        lastReport = now
        onTouch()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        lastReport = .distantPast
        report()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        report()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        if numberOfTouches <= touches.count { state = .failed }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .failed
    }
}
