import Foundation
import SwiftData
import SwiftUI

/// Turns a raw barcode into a fully-populated, valued `MediaItem` and inserts
/// (or updates) it in the SwiftData store. Runs on the main actor because it
/// touches the ModelContext; network work is awaited off the main thread.
@MainActor
final class ImportEngine: ObservableObject {

    enum Status: Equatable {
        case idle
        case working(barcode: String)
        case added(title: String)
        case updated(title: String)
        case duplicateSkipped(title: String)
        case failed(barcode: String, message: String)
    }

    @Published var status: Status = .idle
    /// Rolling log of recent scans for the activity feed.
    @Published var recent: [String] = []

    private let client: DiscogsClient
    private let settings: AppSettings
    let modelContext: ModelContext

    /// Barcodes currently being processed, to ignore rapid re-reads of the same code.
    private var inFlight: Set<String> = []

    init(settings: AppSettings, modelContext: ModelContext) {
        self.settings = settings
        self.client = DiscogsClient(settings: settings)
        self.modelContext = modelContext
    }

    /// Entry point from the scanner. Deduplicates in-flight reads.
    func handleScannedBarcode(_ raw: String) {
        let barcode = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !barcode.isEmpty, !inFlight.contains(barcode) else { return }
        inFlight.insert(barcode)
        Task { await process(barcode: barcode) }
    }

    /// Manual entry / re-lookup path.
    func lookup(barcode: String) {
        handleScannedBarcode(barcode)
    }

    private func process(barcode: String) async {
        defer { inFlight.remove(barcode) }
        status = .working(barcode: barcode)

        // Already in the library? Bump quantity and refresh its valuation.
        if let existing = fetchExisting(barcode: barcode) {
            existing.quantity += 1
            existing.dateScanned = Date()
            await refreshValuation(for: existing)
            save()
            status = .updated(title: existing.title)
            pushRecent("↑ \(existing.title) ×\(existing.quantity)")
            return
        }

        do {
            let results = try await client.searchByBarcode(barcode)
            guard let hit = results.first(where: { $0.id != nil }) else {
                throw DiscogsError.noResults
            }
            let releaseID = hit.id!
            let item = MediaItem(barcode: barcode, discogsReleaseID: releaseID)

            // Full metadata.
            let (release, rawData) = try await client.fetchRelease(id: releaseID)
            apply(release: release, rawData: rawData, fallback: hit, to: item)

            // Valuation from all available asking-price sources.
            await refreshValuation(for: item)

            modelContext.insert(item)
            save()
            status = .added(title: item.title)
            pushRecent("＋ \(item.title) — \(item.displayValue)")
        } catch {
            let message = (error as? DiscogsError)?.errorDescription ?? error.localizedDescription
            status = .failed(barcode: barcode, message: message)
            pushRecent("✕ \(barcode) — \(message)")
        }
    }

    // MARK: - Population

    private func apply(release: DiscogsRelease, rawData: Data, fallback: DiscogsSearchResult, to item: MediaItem) {
        item.title = release.title ?? fallback.title ?? "Untitled"
        item.artist = release.artistName
        // Search "title" is often "Artist - Title"; split it out if we lack an artist.
        if item.artist == "Unknown Artist", let t = fallback.title, t.contains(" - ") {
            let parts = t.components(separatedBy: " - ")
            item.artist = parts.first ?? item.artist
            item.title = parts.dropFirst().joined(separator: " - ")
        }
        item.formatDescription = release.formatDescription.isEmpty
            ? (fallback.format?.joined(separator: ", ") ?? "")
            : release.formatDescription
        let tokens = release.formatTokens.isEmpty ? (fallback.format ?? []) : release.formatTokens
        item.categoryRaw = MediaCategory.classify(from: tokens).rawValue
        item.year = release.year ?? Int(fallback.year ?? "") ?? 0
        item.country = release.country ?? fallback.country ?? ""
        item.genres = release.genres ?? fallback.genre ?? []
        item.styles = release.styles ?? fallback.style ?? []
        item.labels = release.labelNames.isEmpty ? (fallback.label ?? []) : release.labelNames
        item.catalogNumber = release.catalogNumber.isEmpty ? (fallback.catno ?? "") : release.catalogNumber
        item.thumbURL = fallback.thumb ?? release.thumb ?? ""
        item.coverURL = release.primaryCoverURL.isEmpty ? (fallback.cover_image ?? "") : release.primaryCoverURL
        item.discogsURL = release.uri ?? "https://www.discogs.com/release/\(item.discogsReleaseID)"
        item.currency = settings.currency
        item.rawMetadataJSON = String(data: rawData, encoding: .utf8) ?? "{}"
    }

    /// Collects every asking-price data point we can and stores the average.
    private func refreshValuation(for item: MediaItem) async {
        var prices: [Double] = []
        var breakdown: [String: Double] = [:]

        // 1. Per-condition suggested asking prices (best signal, if available).
        if let suggestions = await client.fetchPriceSuggestions(releaseID: item.discogsReleaseID) {
            for (grade, value) in suggestions.byCondition {
                prices.append(value)
                breakdown[grade] = value
            }
        }

        // 2. Live marketplace floor + count.
        if let stats = try? await client.fetchStats(releaseID: item.discogsReleaseID) {
            item.numberForSale = stats.num_for_sale ?? item.numberForSale
            if let low = stats.lowest_price?.value {
                prices.append(low)
                breakdown["Lowest listed"] = low
            }
        }

        item.askingPrices = prices
        item.priceBreakdownJSON = (try? String(data: JSONEncoder().encode(breakdown), encoding: .utf8) ?? "{}") ?? "{}"
        item.estimatedValue = prices.isEmpty ? nil : (prices.reduce(0, +) / Double(prices.count))
        item.currency = settings.currency
    }

    // MARK: - Store helpers

    private func fetchExisting(barcode: String) -> MediaItem? {
        let descriptor = FetchDescriptor<MediaItem>(predicate: #Predicate { $0.barcode == barcode })
        return try? modelContext.fetch(descriptor).first
    }

    private func save() {
        do { try modelContext.save() } catch { print("Shelf save error: \(error)") }
    }

    private func pushRecent(_ line: String) {
        recent.insert(line, at: 0)
        if recent.count > 40 { recent.removeLast() }
    }
}
