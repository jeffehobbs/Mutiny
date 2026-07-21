import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext

    @State private var showResetConfirm = false
    @State private var exportMessage: String?
    @State private var resetMessage: String?

    var body: some View {
        TabView {
            discogsTab
                .tabItem { Label("Discogs", systemImage: "network") }
            libraryTab
                .tabItem { Label("Library", systemImage: "externaldrive") }
        }
        .padding(20)
        .frame(width: 520, height: 430)
    }

    // MARK: - Discogs tab

    private var discogsTab: some View {
        Form {
            Section {
                SecureField("Personal access token", text: $settings.discogsToken)
                    .textFieldStyle(.roundedBorder)
                Text("Create one at discogs.com ▸ Settings ▸ Developers. Needed for barcode search, metadata and pricing.")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = URL(string: "https://www.discogs.com/settings/developers") {
                    Link("Open Discogs Developer settings", destination: url).font(.caption)
                }
            } header: { Text("API Token") }

            Section {
                TextField("User-Agent", text: $settings.userAgent)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Text("Discogs requires a unique User-Agent per app. Yours is seeded with a per-install id.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset default") {
                        settings.userAgent = "Shelf/1.0 +macos (scan-\(settings.installID))"
                    }.font(.caption)
                }
            } header: { Text("User-Agent") }

            Section {
                Picker("Currency", selection: $settings.currency) {
                    ForEach(AppSettings.currencies, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                Text("Newly scanned items are valued in this currency.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Valuation") }

            Section {
                Toggle("Play a sound on each successful scan", isOn: $settings.playSoundOnScan)
                Toggle("Auto-add the first matching release", isOn: $settings.autoAddSingleResult)
            } header: { Text("Scanning") }
        }
        .formStyle(.grouped)
    }

    // MARK: - Library tab

    private var libraryTab: some View {
        Form {
            Section {
                Button {
                    exportCSV()
                } label: {
                    Label("Export library as CSV…", systemImage: "square.and.arrow.up")
                }
                if let exportMessage {
                    Text(exportMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Exports every scanned item with its full metadata and all collected asking prices.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Export") }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("Reset database…", systemImage: "trash")
                }
                if let resetMessage {
                    Text(resetMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Permanently deletes every scanned item. This cannot be undone.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Danger Zone") }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete the entire library?",
                            isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { resetDatabase() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All scanned items and their metadata will be removed. Consider exporting a CSV first.")
        }
    }

    // MARK: - Actions

    private func allItems() -> [MediaItem] {
        (try? modelContext.fetch(FetchDescriptor<MediaItem>(
            sortBy: [SortDescriptor(\.artist), SortDescriptor(\.title)]))) ?? []
    }

    private func exportCSV() {
        let items = allItems()
        guard !items.isEmpty else { exportMessage = "Nothing to export yet."; return }
        let csv = CSVExporter.csv(for: items)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Shelf Library.csv"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.data(using: .utf8)?.write(to: url)
                exportMessage = "Exported \(items.count) item\(items.count == 1 ? "" : "s") to \(url.lastPathComponent)."
            } catch {
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func resetDatabase() {
        do {
            try modelContext.delete(model: MediaItem.self)
            try modelContext.save()
            Task { await ImageCache.shared.clear() }
            resetMessage = "Library cleared."
        } catch {
            resetMessage = "Reset failed: \(error.localizedDescription)"
        }
    }
}
