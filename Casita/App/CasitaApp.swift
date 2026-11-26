import SwiftUI

@main
struct CasitaApp: App {
    @UIApplicationDelegateAdaptor private var delegate: CasitaAppDelegate
    @State private var model = AppModel()

    init() {
        #if DEBUG
        AppModel.freshStartIfAsked()
        #endif
        RevenueCatConfig.configure()
        BackupScheduler.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .lockGuard()
                .environment(model)
                .environment(Entitlements.shared)
                .preferredColorScheme(.dark)
                .task {
                    MediaTemp.sweep()
                    Entitlements.shared.start()
                    model.start()
                    await BackupScheduler.shared.refreshUploadStatus()
                }
                .onChange(of: Entitlements.shared.isSubscribed) { _, _ in BackupScheduler.shared.schedule() }
        }
    }
}

final class CasitaAppDelegate: NSObject, UIApplicationDelegate {
    /// Third-party keyboards may send what is typed off the iPhone: space
    /// names, web logins, recovery sentences. Only Apple's keyboard types here.
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier identifier: UIApplication.ExtensionPointIdentifier) -> Bool {
        identifier != .keyboard
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AgeCheck.under18Key) private var under18 = false

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-designGallery") { DesignGallery() } else { phases }
            #else
            phases
            #endif
        }
        .overlay {
            if under18 { AgeStopView() }
        }
        // A cover, not a sheet: a sheet leaves the entry screen's logo and
        // "Forgot code?" showing behind the clock.
        .fullScreenCover(isPresented: Bindable(model).forgotCodeShown) {
            ForgotCodeFlow()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, model.phase != .firstRun, model.phase != .loading else { return }
            BackupScheduler.shared.backUpOnLeaving()
        }
    }

    @ViewBuilder private var phases: some View {
        switch model.phase {
        case .loading: Color.black.ignoresSafeArea()
        case .firstRun: OnboardingFlow()
        case .locked: EntryView(model: model)
        case .open(let space): SpaceView(space: space).id(space)
        }
    }
}
