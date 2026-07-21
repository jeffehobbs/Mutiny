import SwiftUI
import SwiftData

@main
struct MutinyApp: App {
    let container: ModelContainer
    @StateObject private var settings = AppSettings.shared

    init() {
        do {
            container = try ModelContainer(for: MediaItem.self)
        } catch {
            fatalError("Failed to create the Mutiny data store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(modelContext: container.mainContext)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(container)
        .commands {
            CommandGroup(replacing: .newItem) {} // no document "new"
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .modelContainer(container)
                .frame(width: 520)
        }
    }
}
