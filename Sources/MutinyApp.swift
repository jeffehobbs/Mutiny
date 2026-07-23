import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

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
            CommandGroup(replacing: .newItem) {
                Button("Generate Report…") { generateReport() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .modelContainer(container)
                .frame(width: 520)
        }
    }

    /// File ▸ Generate Report… — writes a buyer-facing PDF valuation report and
    /// opens it. Values honor the "excluded from sale" flag.
    private func generateReport() {
        let items = (try? container.mainContext.fetch(FetchDescriptor<MediaItem>())) ?? []
        guard let data = ReportGenerator.pdf(for: items, currency: settings.currency) else {
            NSSound.beep(); return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = "Mutiny Collection Report.pdf"
        panel.canCreateDirectories = true
        panel.title = "Save Collection Report"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                NSWorkspace.shared.open(url)
            } catch {
                NSSound.beep()
            }
        }
    }
}
