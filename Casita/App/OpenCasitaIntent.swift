import AppIntents

/// The app-side copy of the widget extension's intent: a control or Siri
/// runs it in the app process, which brings Casita to the entry screen.
/// Keep it identical to `CasitaWidgets/CasitaWidgets.swift`.
struct OpenCasitaIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Casita"
    static let description = IntentDescription("Opens Casita at the code screen.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        .result()
    }
}
