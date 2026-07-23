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
    @State private var showConditionBreakdown = false
    @State private var showTopValued = false

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
        filtered
            .filter { !$0.excludedFromSale }
            .reduce(0) { $0 + ($1.estimatedValue ?? 0) * Double($1.quantity) }
    }

    private var totalCount: Int {
        filtered.reduce(0) { $0 + $1.quantity }
    }

    private var selectedItem: MediaItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    /// The ten most valuable titles across the whole collection (by unit worth).
    private var topValued: [MediaItem] {
        items
            .filter { ($0.estimatedValue ?? 0) > 0 }
            .sorted { ($0.estimatedValue ?? 0) > ($1.estimatedValue ?? 0) }
            .prefix(10)
            .map { $0 }
    }

    /// Discogs condition grades, best → worst, for ordering the breakdown.
    private static let conditionOrder = [
        "Mint (M)", "Near Mint (NM or M-)", "Very Good Plus (VG+)",
        "Very Good (VG)", "Good Plus (G+)", "Good (G)", "Fair (F)", "Poor (P)"
    ]

    struct ConditionTotal: Identifiable {
        let grade: String
        let total: Double
        let pricedTitles: Int
        var id: String { grade }
    }

    /// For each condition grade present anywhere in the shown collection, the
    /// total the collection would be worth if every copy carried that grade,
    /// using Discogs per-condition asking prices × quantity.
    private var conditionTotals: [ConditionTotal] {
        let sellable = filtered.filter { !$0.excludedFromSale }
        var present = Set<String>()
        for item in sellable { present.formUnion(item.priceBreakdown.keys) }
        let ordered = Self.conditionOrder.filter { present.contains($0) }
            + present.subtracting(Self.conditionOrder).sorted()
        return ordered.map { grade in
            var total = 0.0
            var titles = 0
            for item in sellable {
                if let price = item.priceBreakdown[grade] {
                    total += price * Double(item.quantity)
                    titles += 1
                }
            }
            return ConditionTotal(grade: grade, total: total, pricedTitles: titles)
        }
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
                    DetailView(item: selectedItem, engine: engine)
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
            Button {
                showConditionBreakdown.toggle()
            } label: {
                VStack(spacing: 1) {
                    Text(totalValue.formatted(.currency(code: settings.currency)))
                        .font(.headline).monospacedDigit()
                    Text("\(totalCount) item\(totalCount == 1 ? "" : "s") · \(filtered.count) title\(filtered.count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show collection value by condition grade")
            .popover(isPresented: $showConditionBreakdown, arrowEdge: .bottom) {
                conditionBreakdownPopover
            }
        }
        ToolbarItem {
            Button {
                showTopValued.toggle()
            } label: { Label("Top value", systemImage: "trophy") }
            .help("Show the ten most valuable items")
            .popover(isPresented: $showTopValued, arrowEdge: .bottom) {
                topValuedPopover
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

    // MARK: - Condition breakdown popover

    private var conditionBreakdownPopover: some View {
        let totals = conditionTotals
        let titleCount = filtered.filter { !$0.excludedFromSale }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Value by condition")
                .font(.headline)
            Text("What the \(titleCount) shown title\(titleCount == 1 ? "" : "s") would fetch if every copy were graded the same, from Discogs per-condition asking prices.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if totals.isEmpty {
                Text("No per-condition prices available yet. Discogs price suggestions require a token whose account has complete seller settings (add one in Settings ⌘,).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Divider()
                ForEach(totals) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.grade).font(.callout)
                        Spacer(minLength: 24)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(row.total.formatted(.currency(code: settings.currency)))
                                .font(.callout.weight(.semibold).monospacedDigit())
                            if row.pricedTitles < titleCount {
                                Text("\(row.pricedTitles)/\(titleCount) titles priced")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Top valued popover

    private var topValuedPopover: some View {
        let leaders = topValued
        return VStack(alignment: .leading, spacing: 10) {
            Label("Most valuable", systemImage: "trophy.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            if leaders.isEmpty {
                Text("No valued items yet. Scan some media (and add a Discogs token in Settings ⌘, for prices) and the top ten will show up here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Divider()
                ForEach(Array(leaders.enumerated()), id: \.element.id) { index, item in
                    Button {
                        selection = item.id
                        showInspector = true
                        showTopValued = false
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            RemoteImage(urlString: item.thumbURL.isEmpty ? item.coverURL : item.thumbURL)
                                .frame(width: 34, height: 34)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.callout).lineLimit(1)
                                Text(item.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Text(item.displayValue)
                                .font(.callout.weight(.semibold).monospacedDigit())
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
