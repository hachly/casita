import AppIntents
import SwiftUI
import WidgetKit

@main
struct CasitaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        CasitaHomeWidget()
        CasitaControl()
    }
}

/// Opens Casita at its entry screen. Runs in the app, so the same type also
/// lives in the app target (`Casita/App/OpenCasitaIntent.swift`).
struct OpenCasitaIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Casita"
    static let description = IntentDescription("Opens Casita at the code screen.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Lock Screen, Control Center and Action Button button.
struct CasitaControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.hachly.casita.control") {
            ControlWidgetButton(action: OpenCasitaIntent()) {
                Label("Casita", systemImage: "house")
            }
        }
        .displayName("Open Casita")
        .description("Opens Casita at the code screen.")
    }
}

/// A Home Screen tile that opens Casita. Shows nothing but the name.
struct CasitaHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.hachly.casita.home", provider: StaticProvider()) { _ in
            CasitaHomeView()
                .containerBackground(.black, for: .widget)
                .widgetURL(URL(string: "casita://open"))
        }
        .configurationDisplayName("Casita")
        .description("Opens Casita.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private struct CasitaHomeView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "house")
                .font(.system(size: 28, weight: .regular))
            Text("Casita")
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StaticProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}
