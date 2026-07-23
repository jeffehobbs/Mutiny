import AppKit
import CoreText

/// Builds a polished, multi-page PDF valuation report suitable for handing to a
/// used-CD / record buyer: headline valuation, a value-by-condition range,
/// the collection's most valuable pieces, and a per-format breakdown.
///
/// All monetary figures exclude items marked "excluded from sale," matching the
/// running total shown in the app.
enum ReportGenerator {

    // MARK: - Public API

    static func pdf(for allItems: [MediaItem], currency: String) -> Data? {
        let sections = buildContent(allItems: allItems, currency: currency)
        return renderPDF(sections)
    }

    // MARK: - Palette & type (explicit colors — PDFs have no light/dark mode)

    private static let ink     = NSColor(white: 0.11, alpha: 1)
    private static let subInk  = NSColor(white: 0.42, alpha: 1)
    private static let faint   = NSColor(white: 0.58, alpha: 1)
    private static let accent  = NSColor(red: 0.60, green: 0.11, blue: 0.16, alpha: 1) // crimson

    // MARK: - Content assembly

    /// Each element is a "page group" that begins on a fresh page (and may flow
    /// onto further pages if long). The header/overview/condition live on the
    /// first group; the highlights start the second, so they open on page 2.
    private static func buildContent(allItems: [MediaItem], currency: String) -> [NSAttributedString] {
        let out = NSMutableAttributedString()
        let sellable = allItems.filter { !$0.excludedFromSale }

        // ---- Header ------------------------------------------------------
        append(out, "Collection Valuation Report\n", title())
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .long, timeStyle: .short)
        append(out, "Generated \(stamp)   ·   Values in \(currency)\n", meta())

        guard !sellable.isEmpty else {
            append(out, "\nThis collection is currently empty.\n", body())
            return [out]
        }

        // ---- Overview metrics -------------------------------------------
        let titleCount = sellable.count
        let unitCount  = sellable.reduce(0) { $0 + $1.quantity }
        let valuedTitles = sellable.filter { ($0.estimatedValue ?? 0) > 0 }.count
        let totalValue = sellable.reduce(0.0) { $0 + ($1.estimatedValue ?? 0) * Double($1.quantity) }
        let avgUnit = unitCount > 0 ? totalValue / Double(unitCount) : 0
        let years = sellable.map(\.year).filter { $0 > 0 }
        let artists = Set(sellable.map { $0.artist.lowercased() }).count

        append(out, "\nOverview\n", heading())
        let lead = "This collection comprises \(titleCount) title\(titleCount == 1 ? "" : "s") "
            + "(\(unitCount) individual unit\(unitCount == 1 ? "" : "s")), with a combined estimated resale value of "
            + "\(money(totalValue, currency)). Figures below reflect current Discogs market data.\n"
        append(out, lead, body())

        metricRow(out, "Titles in collection", "\(titleCount)")
        metricRow(out, "Total units", "\(unitCount)")
        metricRow(out, "Titles with market value", "\(valuedTitles) of \(titleCount)")
        metricRow(out, "Estimated collection value", money(totalValue, currency))
        metricRow(out, "Average value per unit", money(avgUnit, currency))
        if let lo = years.min(), let hi = years.max() {
            metricRow(out, "Release years", lo == hi ? "\(lo)" : "\(lo)–\(hi)")
        }
        metricRow(out, "Distinct artists", "\(artists)")

        // ---- Value by condition -----------------------------------------
        append(out, "\nEstimated Value by Condition\n", heading())
        let conditions = conditionTotals(sellable)
        if conditions.isEmpty {
            append(out, "No per-condition pricing is available for this collection. "
                 + "Discogs price suggestions require a seller-enabled API token.\n", body())
        } else {
            append(out, "If every copy were graded uniformly, the collection's total asking "
                 + "value would fall in the range below — from a top-grade to a well-worn collection:\n", body())
            for row in conditions {
                let coverage = row.pricedTitles < titleCount ? "   (\(row.pricedTitles)/\(titleCount) titles)" : ""
                metricRow(out, row.grade + coverage, money(row.total, currency))
            }
            if let best = conditions.first, let worst = conditions.last, best.grade != worst.grade {
                append(out, "\nHeadline range: \(money(best.total, currency)) (\(best.grade)) "
                     + "down to \(money(worst.total, currency)) (\(worst.grade)).\n", note())
            }
        }

        // ---- Highlights (starts on page 2) -------------------------------
        let page2 = NSMutableAttributedString()
        let leaders = sellable
            .filter { ($0.estimatedValue ?? 0) > 0 }
            .sorted { ($0.estimatedValue ?? 0) > ($1.estimatedValue ?? 0) }
            .prefix(20)
        if !leaders.isEmpty {
            append(page2, "Collection Highlights — Most Valuable\n", heading())
            append(page2, "The standout pieces by estimated value:\n", body())
            for (i, item) in leaders.enumerated() {
                var line = "\(i + 1).  \(clip(item.title, 42))"
                if !item.artist.isEmpty && item.artist != "Unknown Artist" {
                    line += " — \(clip(item.artist, 28))"
                }
                let detail = [item.category.rawValue, item.year > 0 ? "\(item.year)" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
                if !detail.isEmpty { line += "  (\(detail))" }
                metricRow(page2, line, money(item.estimatedValue ?? 0, currency))
            }
        }

        // ---- Methodology -------------------------------------------------
        append(page2, "\nMethodology & Notes\n", heading())
        append(page2, "Each item's value is the average of the asking-price data points collected from "
             + "Discogs: per-condition price suggestions where available, plus the live marketplace floor. "
             + "Per-condition totals multiply each title's suggested price for that grade by its quantity, "
             + "and cover only titles for which Discogs returned a suggestion for that grade. These are "
             + "asking prices, not guaranteed sale prices, and fluctuate with the market.\n", footnote())

        return [out, page2]
    }

    // MARK: - Value-by-condition (mirrors the app's in-UI breakdown)

    private struct ConditionTotal { let grade: String; let total: Double; let pricedTitles: Int }

    private static let conditionOrder = [
        "Mint (M)", "Near Mint (NM or M-)", "Very Good Plus (VG+)",
        "Very Good (VG)", "Good Plus (G+)", "Good (G)", "Fair (F)", "Poor (P)"
    ]

    private static func conditionTotals(_ items: [MediaItem]) -> [ConditionTotal] {
        var present = Set<String>()
        for item in items { present.formUnion(item.priceBreakdown.keys) }
        // Only the standard Discogs grades, best→worst; ignore non-grade keys
        // such as the marketplace "Lowest listed" floor.
        let ordered = conditionOrder.filter { present.contains($0) }
        return ordered.map { grade in
            var total = 0.0, titles = 0
            for item in items {
                if let price = item.priceBreakdown[grade] {
                    total += price * Double(item.quantity)
                    titles += 1
                }
            }
            return ConditionTotal(grade: grade, total: total, pricedTitles: titles)
        }
    }

    // MARK: - PDF rendering (CoreText pagination)

    private static func renderPDF(_ sections: [NSAttributedString]) -> Data? {
        let pageSize = CGSize(width: 612, height: 792)   // US Letter
        let margin: CGFloat = 56
        let textRect = CGRect(x: margin, y: margin,
                              width: pageSize.width - 2 * margin,
                              height: pageSize.height - 2 * margin)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        // Pin an explicit, identical portrait media box on *every* page so no
        // page (e.g. the second) inherits a rotation or a different box.
        let boxData = withUnsafeBytes(of: mediaBox) { Data($0) }
        let pageInfo = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
        let path = CGPath(rect: textRect, transform: nil)
        var page = 1

        // Each section begins on a fresh page; long sections flow onto more.
        for attr in sections where attr.length > 0 {
            let framesetter = CTFramesetterCreateWithAttributedString(attr as CFAttributedString)
            var start = 0
            while start < attr.length {
                ctx.beginPDFPage(pageInfo)
                ctx.textMatrix = .identity

                let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(start, 0), path, nil)
                CTFrameDraw(frame, ctx)
                drawFooter(page: page, in: ctx, pageSize: pageSize, margin: margin)

                let visible = CTFrameGetVisibleStringRange(frame)
                ctx.endPDFPage()
                if visible.length == 0 { break }   // guard against non-advancing layout
                start += visible.length
                page += 1
            }
        }
        ctx.closePDF()
        return data as Data
    }

    private static func drawFooter(page: Int, in ctx: CGContext, pageSize: CGSize, margin: CGFloat) {
        let footer = NSAttributedString(string: "☠  Mutiny  ·  page \(page)", attributes: [
            .font: NSFont.systemFont(ofSize: 8, weight: .regular),
            .foregroundColor: faint
        ])
        let line = CTLineCreateWithAttributedString(footer as CFAttributedString)
        ctx.textPosition = CGPoint(x: margin, y: margin - 26)
        CTLineDraw(line, ctx)
    }

    // MARK: - Text styling helpers

    private static func append(_ out: NSMutableAttributedString, _ s: String,
                               _ attrs: [NSAttributedString.Key: Any]) {
        out.append(NSAttributedString(string: s, attributes: attrs))
    }

    /// A left label + right-aligned value on one line (tab stop at the margin).
    private static func metricRow(_ out: NSMutableAttributedString, _ label: String, _ value: String) {
        let p = NSMutableParagraphStyle()
        p.tabStops = [NSTextTab(textAlignment: .right, location: 500)]
        p.defaultTabInterval = 500
        p.paragraphSpacing = 2
        p.lineBreakMode = .byTruncatingTail
        out.append(NSAttributedString(string: label + "\t" + value + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: ink,
            .paragraphStyle: p
        ]))
    }

    private static func title() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = 1
        return [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: ink, .paragraphStyle: p]
    }
    private static func meta() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = 8
        return [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: subInk, .paragraphStyle: p]
    }
    private static func heading() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.paragraphSpacingBefore = 12; p.paragraphSpacing = 5
        return [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: accent, .paragraphStyle: p]
    }
    private static func body() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = 6; p.lineSpacing = 1.5
        return [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink, .paragraphStyle: p]
    }
    private static func note() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = 4
        return [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink, .paragraphStyle: p]
    }
    private static func footnote() -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = 4; p.lineSpacing = 1.5
        return [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: subInk, .paragraphStyle: p]
    }

    // MARK: - Formatting

    private static func money(_ value: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(max(1, n - 1))) + "…"
    }
}
