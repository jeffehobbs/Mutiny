import Foundation
import SwiftData

/// Broad physical-media category, used for filtering the shelf.
enum MediaCategory: String, Codable, CaseIterable, Identifiable {
    case cd = "CD"
    case vinyl = "Vinyl"
    case cassette = "Cassette"
    case other = "Other"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cd: return "opticaldisc"
        case .vinyl: return "record.circle"
        case .cassette: return "recordingtape"
        case .other: return "shippingbox"
        }
    }

    /// Best-effort classification from a Discogs format description.
    static func classify(from formats: [String]) -> MediaCategory {
        let joined = formats.joined(separator: " ").lowercased()
        if joined.contains("vinyl") || joined.contains("lp") || joined.contains("\"") { return .vinyl }
        if joined.contains("cassette") || joined.contains("cass") { return .cassette }
        if joined.contains("cd") || joined.contains("cdr") || joined.contains("compact disc") { return .cd }
        return .other
    }
}

/// One scanned physical item plus everything Discogs knows about it and every
/// asking price we could collect for it.
@Model
final class MediaItem {
    @Attribute(.unique) var id: UUID
    var barcode: String
    var discogsReleaseID: Int

    var title: String
    var artist: String
    var formatDescription: String
    var categoryRaw: String
    var year: Int
    var country: String
    var genres: [String]
    var styles: [String]
    var labels: [String]
    var catalogNumber: String

    var thumbURL: String
    var coverURL: String
    var discogsURL: String

    /// Number of copies currently for sale on the Discogs marketplace.
    var numberForSale: Int
    /// Currency all monetary values are expressed in (e.g. "USD").
    var currency: String
    /// Every asking-price data point we collected (per-condition suggestions +
    /// the live marketplace floor). "Worth" is the average of these.
    var askingPrices: [Double]
    /// The computed worth = average of `askingPrices`, or nil if none found.
    var estimatedValue: Double?
    /// JSON map of condition grade -> suggested price, for the detail view.
    var priceBreakdownJSON: String

    /// Complete release metadata as returned by Discogs, for CSV / archival.
    var rawMetadataJSON: String

    var quantity: Int
    var dateScanned: Date
    var notes: String

    init(barcode: String, discogsReleaseID: Int) {
        self.id = UUID()
        self.barcode = barcode
        self.discogsReleaseID = discogsReleaseID
        self.title = ""
        self.artist = ""
        self.formatDescription = ""
        self.categoryRaw = MediaCategory.other.rawValue
        self.year = 0
        self.country = ""
        self.genres = []
        self.styles = []
        self.labels = []
        self.catalogNumber = ""
        self.thumbURL = ""
        self.coverURL = ""
        self.discogsURL = ""
        self.numberForSale = 0
        self.currency = "USD"
        self.askingPrices = []
        self.estimatedValue = nil
        self.priceBreakdownJSON = "{}"
        self.rawMetadataJSON = "{}"
        self.quantity = 1
        self.dateScanned = Date()
        self.notes = ""
    }

    var category: MediaCategory {
        MediaCategory(rawValue: categoryRaw) ?? .other
    }

    /// condition grade -> suggested price, decoded from `priceBreakdownJSON`.
    var priceBreakdown: [String: Double] {
        guard let data = priceBreakdownJSON.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return dict
    }

    var displayValue: String {
        guard let v = estimatedValue else { return "—" }
        return v.formatted(.currency(code: currency))
    }
}
