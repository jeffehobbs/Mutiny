import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext

    @StateObject private var engine: ImportEngine
    @StateObject private var scanner = BarcodeScanner()

    @Query private var items: [MediaItem]

    @State private var searchText = ""
    @State private var categoryFilter: MediaCategory? = nil
    @State private var sort: SortOption = .recent
    @State private var selection: UUID?
    @State private var showInspector = true
    @State private var manualBarcode = ""

    init(modelContext: ModelContext) {
        _engine = StateObject(wrappedValue: ImportEngine(settings: .shared, modelContext: modelContext))
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case recent = "Recently scanned"
        case value = "Value (high→low)"
        case artist = "Artist"
        case title = "Title"
        var id: String { rawValue }
    }

    // MARK: - Derived data

    private var filtered: [MediaItem] {
        var list = items
        if let cat = categoryFilter {
            list = list.filter { $0.category == cat }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { item in
                item.title.lowercased().contains(q)
                || item.artist.lowercased().contains(q)
                || item.barcode.contains(q)
                || item.labels.joined(separator: " ").lowercased().contains(q)
                || item.genres.joined(separator: " ").lowercased().contains(q)
                || item.styles.joined(separator: " ").lowercased().contains(q)
            }
        }
        switch sort {
        case .recent: list.sort { $0.dateScanned > $1.dateScanned }
        case .value: list.sort { ($0.estimatedValue ?? -1) > ($1.estimatedValue ?? -1) }
        case .artist: list.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return list
    }

    private var totalValue: Double {
        filtered.reduce(0) { $0 + ($1.estimatedValue ?? 0) * Double($1.quantity) }
    }

    private var totalCount: Int {
        filtered.reduce(0) { $0 + $1.quantity }
    }

    private var selectedItem: MediaItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            SidebarView(scanner: scanner,
                        engine: engine,
                        categoryFilter: $categoryFilter,
                        manualBarcode: $manualBarcode,
                        counts: categoryCounts)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            ShelfGridView(items: filtered, selection: $selection)
                .navigationTitle(categoryFilter?.rawValue ?? "All Media")
                .searchable(text: $searchText, prompt: "Search title, artist, label, genre…")
                .toolbar { toolbarContent }
                .inspector(isPresented: $showInspector) {
                    DetailView(item: selectedItem)
                        .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
                }
        }
        .onAppear {
            scanner.onBarcode = { [weak engine] code in engine?.handleScannedBarcode(code) }
        }
    }

    private var categoryCounts: [MediaCategory: Int] {
        var counts: [MediaCategory: Int] = [:]
        for item in items { counts[item.category, default: 0] += item.quantity }
        return counts
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .status) {
            VStack(spacing: 1) {
                Text(totalValue.formatted(.currency(code: settings.currency)))
                    .font(.headline).monospacedDigit()
                Text("\(totalCount) item\(totalCount == 1 ? "" : "s") · \(filtered.count) title\(filtered.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        ToolbarItem {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOption.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
        }
        ToolbarItem {
            Button {
                withAnimation { showInspector.toggle() }
            } label: { Label("Info", systemImage: "sidebar.trailing") }
        }
    }
}
