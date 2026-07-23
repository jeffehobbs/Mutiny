import Foundation
import SwiftData
import SwiftUI
import AppKit

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

    /// Corrects a mis-scanned format (e.g. a CD that matched the vinyl pressing).
    /// Re-searches the barcode, prefers the Discogs release whose format matches
    /// `category`, and re-fetches its full metadata + valuation in place. If no
    /// distinct release exists for that format, just applies the manual label.
    func correctFormat(for item: MediaItem, to category: MediaCategory) {
        let barcode = item.barcode
        guard !barcode.isEmpty, !inFlight.contains(barcode) else { return }
        inFlight.insert(barcode)
        Task { await recategorize(item, to: category, barcode: barcode) }
    }

    private func recategorize(_ item: MediaItem, to category: MediaCategory, barcode: String) async {
        defer { inFlight.remove(barcode) }
        status = .working(barcode: barcode)
        do {
            let results = try await client.searchByBarcode(barcode)
            let candidates = results.filter { $0.id != nil }
            if let hit = candidates.first(where: { MediaCategory.classify(from: $0.format ?? []) == category }),
               let releaseID = hit.id {
                // A distinct release exists for the requested format — swap to it.
                item.discogsReleaseID = releaseID
                let (release, rawData) = try await client.fetchRelease(id: releaseID)
                apply(release: release, rawData: rawData, fallback: hit, to: item)
                item.categoryRaw = category.rawValue   // honor the explicit choice
                await refreshValuation(for: item)
                save()
                status = .updated(title: item.title)
                pushRecent("↺ \(item.title) → \(category.rawValue)")
                playSound(.success, times: isTopTen(item) ? 3 : 1)
            } else {
                // No separate release for that format; relabel without refetch.
                item.categoryRaw = category.rawValue
                save()
                status = .updated(title: item.title)
                pushRecent("↺ \(item.title) format set to \(category.rawValue) (no separate Discogs release)")
                playSound(.success)
            }
        } catch {
            let message = (error as? DiscogsError)?.errorDescription ?? error.localizedDescription
            status = .failed(barcode: barcode, message: message)
            pushRecent("✕ \(barcode) — \(message)")
            playSound(.failure)
        }
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
            playSound(.success, times: isTopTen(existing) ? 3 : 1)
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
            playSound(.success, times: isTopTen(item) ? 3 : 1)
        } catch {
            let message = (error as? DiscogsError)?.errorDescription ?? error.localizedDescription
            status = .failed(barcode: barcode, message: message)
            pushRecent("✕ \(barcode) — \(message)")
            playSound(.failure)
        }
    }

    // MARK: - Feedback

    private enum Feedback { case success, failure }

    /// Plays a short system sound for a scan outcome, honoring the user's
    /// "play a sound on each successful scan" preference. The failure chime is
    /// gated on the same preference so scanning stays silent when disabled.
    /// `times` > 1 fires a quick celebratory run (used when a scan lands in the
    /// collection's top-ten most valuable).
    private func playSound(_ kind: Feedback, times: Int = 1) {
        guard settings.playSoundOnScan else { return }
        // Named system sounds live in /System/Library/Sounds. "Glass" is a
        // crisp, satisfying confirmation; "Basso" reads clearly as an error.
        let name = (kind == .success) ? "Glass" : "Basso"
        playChime(name: name, remaining: max(1, times), interval: 0.28)
    }

    /// Fires `remaining` copies of a system sound spaced `interval` apart. Each
    /// gets its own NSSound instance so replays don't cut the previous one off.
    private func playChime(name: String, remaining: Int, interval: TimeInterval) {
        NSSound(named: NSSound.Name(name))?.play()
        guard remaining > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.playChime(name: name, remaining: remaining - 1, interval: interval)
        }
    }

    /// Whether `item` currently ranks among the ten most valuable titles in the
    /// whole library (by unit estimated value) — mirrors the trophy list.
    private func isTopTen(_ item: MediaItem) -> Bool {
        guard let value = item.estimatedValue, value > 0 else { return false }
        let all = (try? modelContext.fetch(FetchDescriptor<MediaItem>())) ?? []
        let ranked = all
            .filter { ($0.estimatedValue ?? 0) > 0 }
            .sorted { ($0.estimatedValue ?? 0) > ($1.estimatedValue ?? 0) }
            .prefix(10)
        return ranked.contains { $0.id == item.id }
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
        do { try modelContext.save() } catch { print("Mutiny save error: \(error)") }
    }

    private func pushRecent(_ line: String) {
        recent.insert(line, at: 0)
        if recent.count > 40 { recent.removeLast() }
    }
}
