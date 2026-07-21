import SwiftUI
import SwiftData
import AppKit

/// Right inspector: full metadata + every collected asking price for the
/// selected item.
struct DetailView: View {
    let item: MediaItem?
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if let item {
                content(for: item)
            } else {
                ContentUnavailableView("No selection",
                    systemImage: "hand.tap",
                    description: Text("Pick an item on the shelf to see its details and value."))
            }
        }
    }

    private func content(for item: MediaItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(urlString: item.coverURL.isEmpty ? item.thumbURL : item.coverURL)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.title3.bold())
                    Text(item.artist).font(.headline).foregroundStyle(.secondary)
                }

                valueCard(item)
                metadataCard(item)
                pricesCard(item)
                actions(item)
            }
            .padding(16)
        }
    }

    // MARK: - Cards

    private func valueCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Estimated worth").font(.caption).foregroundStyle(.secondary)
            Text(item.displayValue).font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(item.estimatedValue == nil
                 ? "No asking prices found on Discogs."
                 : "Average of \(item.askingPrices.count) asking price\(item.askingPrices.count == 1 ? "" : "s") · \(item.numberForSale) for sale")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metadataCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Format", item.formatDescription)
            row("Category", item.category.rawValue)
            row("Year", item.year == 0 ? "—" : String(item.year))
            row("Country", item.country.isEmpty ? "—" : item.country)
            row("Label", item.labels.isEmpty ? "—" : item.labels.joined(separator: ", "))
            row("Catalog #", item.catalogNumber.isEmpty ? "—" : item.catalogNumber)
            row("Genre", item.genres.isEmpty ? "—" : item.genres.joined(separator: ", "))
            row("Style", item.styles.isEmpty ? "—" : item.styles.joined(separator: ", "))
            row("Barcode", item.barcode)
            row("Scanned", item.dateScanned.formatted(date: .abbreviated, time: .shortened))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func pricesCard(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Asking prices").font(.subheadline.weight(.semibold))
            let breakdown = item.priceBreakdown.sorted { $0.value > $1.value }
            if breakdown.isEmpty {
                Text("None available. Discogs price suggestions require the API token's account to have complete seller settings; the live marketplace floor is used otherwise.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(breakdown, id: \.key) { pair in
                    HStack {
                        Text(pair.key).font(.caption)
                        Spacer()
                        Text(pair.value.formatted(.currency(code: item.currency)))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func actions(_ item: MediaItem) -> some View {
        VStack(spacing: 8) {
            if let url = URL(string: item.discogsURL), !item.discogsURL.isEmpty {
                Link(destination: url) {
                    Label("View on Discogs", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Stepper("Quantity: \(item.quantity)", value: Binding(
                    get: { item.quantity },
                    set: { item.quantity = max(1, $0); try? modelContext.save() }
                ), in: 1...999)
            }
            Button(role: .destructive) {
                modelContext.delete(item)
                try? modelContext.save()
            } label: {
                Label("Remove from Shelf", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
