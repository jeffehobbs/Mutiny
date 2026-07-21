import Foundation

/// Builds a spreadsheet-friendly CSV of the whole library, including every
/// collected asking price.
enum CSVExporter {
    static let columns = [
        "Barcode", "Title", "Artist", "Category", "Format", "Year", "Country",
        "Labels", "Catalog #", "Genres", "Styles", "Quantity",
        "Estimated Value", "Currency", "# For Sale", "# Asking Prices",
        "All Asking Prices", "Price Breakdown", "Discogs Release ID",
        "Discogs URL", "Date Scanned", "Notes"
    ]

    static func csv(for items: [MediaItem]) -> String {
        var rows = [columns.map(escape).joined(separator: ",")]
        let df = ISO8601DateFormatter()
        for item in items {
            let breakdownPairs: [String] = item.priceBreakdown
                .sorted { $0.key < $1.key }
                .map { (pair: (key: String, value: Double)) -> String in
                    let amount = String(format: "%.2f", pair.value)
                    return pair.key + "=" + amount
                }
            let breakdown = breakdownPairs.joined(separator: "; ")
            let asking = item.askingPrices.map { String(format: "%.2f", $0) }.joined(separator: "; ")
            let value = item.estimatedValue.map { String(format: "%.2f", $0) } ?? ""
            let fields: [String] = [
                item.barcode,
                item.title,
                item.artist,
                item.category.rawValue,
                item.formatDescription,
                item.year == 0 ? "" : String(item.year),
                item.country,
                item.labels.joined(separator: "; "),
                item.catalogNumber,
                item.genres.joined(separator: "; "),
                item.styles.joined(separator: "; "),
                String(item.quantity),
                value,
                item.currency,
                String(item.numberForSale),
                String(item.askingPrices.count),
                asking,
                breakdown,
                String(item.discogsReleaseID),
                item.discogsURL,
                df.string(from: item.dateScanned),
                item.notes
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n")
    }

    /// RFC-4180 quoting.
    private static func escape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
