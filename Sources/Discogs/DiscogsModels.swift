import Foundation

// Minimal, tolerant Decodable models covering only the fields Shelf needs.
// All optional so a missing/renamed field never fails the whole decode.

struct DiscogsSearchResponse: Decodable {
    let results: [DiscogsSearchResult]?
}

struct DiscogsSearchResult: Decodable {
    let id: Int?
    let type: String?
    let title: String?
    let year: String?
    let country: String?
    let thumb: String?
    let cover_image: String?
    let format: [String]?
    let label: [String]?
    let genre: [String]?
    let style: [String]?
    let barcode: [String]?
    let catno: String?
    let resource_url: String?
}

struct DiscogsRelease: Decodable {
    let id: Int?
    let title: String?
    let year: Int?
    let country: String?
    let genres: [String]?
    let styles: [String]?
    let uri: String?
    let thumb: String?
    let num_for_sale: Int?
    let lowest_price: Double?
    let artists: [Artist]?
    let labels: [Label]?
    let formats: [Format]?
    let images: [Image]?

    struct Artist: Decodable { let name: String? }
    struct Label: Decodable { let name: String?; let catno: String? }
    struct Format: Decodable {
        let name: String?
        let qty: String?
        let descriptions: [String]?
    }
    struct Image: Decodable {
        let uri: String?
        let uri150: String?
        let type: String?
    }

    var artistName: String {
        guard let artists, !artists.isEmpty else { return "Unknown Artist" }
        // Discogs appends join phrases like "(2)" disambiguators; keep names simple.
        return artists.compactMap { $0.name }.joined(separator: ", ")
    }

    /// Human-readable format string, e.g. "CD, Album, Reissue".
    var formatDescription: String {
        guard let formats, let first = formats.first else { return "" }
        var parts: [String] = []
        if let name = first.name { parts.append(name) }
        if let descs = first.descriptions { parts.append(contentsOf: descs) }
        return parts.joined(separator: ", ")
    }

    var formatTokens: [String] {
        guard let formats else { return [] }
        return formats.flatMap { f -> [String] in
            var t: [String] = []
            if let n = f.name { t.append(n) }
            if let d = f.descriptions { t.append(contentsOf: d) }
            return t
        }
    }

    var labelNames: [String] { labels?.compactMap { $0.name } ?? [] }
    var catalogNumber: String { labels?.compactMap { $0.catno }.first ?? "" }
    var primaryCoverURL: String {
        images?.first(where: { $0.type == "primary" })?.uri
            ?? images?.first?.uri
            ?? thumb
            ?? ""
    }
}

/// GET /marketplace/stats/{release_id}
struct DiscogsMarketplaceStats: Decodable {
    let num_for_sale: Int?
    let lowest_price: Price?
    let blocked_from_sale: Bool?

    struct Price: Decodable {
        let value: Double?
        let currency: String?
    }
}

/// GET /marketplace/price_suggestions/{release_id}
/// Returns a JSON object keyed by condition grade, each { currency, value }.
struct DiscogsPriceSuggestions {
    /// condition grade -> price value
    let byCondition: [String: Double]
    let currency: String?

    /// Custom parse because keys are arbitrary condition-grade strings.
    static func parse(_ data: Data) -> DiscogsPriceSuggestions? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [String: Double] = [:]
        var currency: String?
        for (grade, raw) in obj {
            guard let entry = raw as? [String: Any] else { continue }
            if let value = entry["value"] as? Double {
                result[grade] = value
            } else if let value = entry["value"] as? Int {
                result[grade] = Double(value)
            } else if let s = entry["value"] as? String, let value = Double(s) {
                result[grade] = value
            }
            if currency == nil { currency = entry["currency"] as? String }
        }
        guard !result.isEmpty else { return nil }
        return DiscogsPriceSuggestions(byCondition: result, currency: currency)
    }
}
