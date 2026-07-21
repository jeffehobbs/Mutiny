import Foundation

enum DiscogsError: LocalizedError {
    case missingToken
    case notFound
    case rateLimited
    case http(Int)
    case network(String)
    case noResults

    var errorDescription: String? {
        switch self {
        case .missingToken: return "No Discogs API token set. Add one in Settings."
        case .notFound: return "No matching release found."
        case .rateLimited: return "Discogs rate limit hit — slowing down."
        case .http(let code): return "Discogs returned HTTP \(code)."
        case .network(let m): return "Network error: \(m)"
        case .noResults: return "No release matched that barcode."
        }
    }
}

/// Serializes and paces all Discogs traffic so we stay under 60 req/min.
actor DiscogsRateLimiter {
    private var lastRequest: Date = .distantPast
    /// ~1.05s between requests keeps us comfortably under 60/min.
    private let minInterval: TimeInterval = 1.05

    func waitForTurn() async {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRequest)
        if elapsed < minInterval {
            let delay = minInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lastRequest = Date()
    }
}

/// Async client for the parts of the Discogs API that Shelf uses.
final class DiscogsClient {
    private let settings: AppSettings
    private let limiter = DiscogsRateLimiter()
    private let session: URLSession
    private let base = "https://api.discogs.com"

    init(settings: AppSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    // MARK: - Request plumbing

    private func makeRequest(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var comps = URLComponents(string: base + path)!
        var items = query
        // Token auth via query param is accepted by Discogs and simplest.
        if settings.hasToken {
            items.append(URLQueryItem(name: "token", value: settings.discogsToken.trimmingCharacters(in: .whitespaces)))
        }
        if !items.isEmpty { comps.queryItems = items }
        guard let url = comps.url else { throw DiscogsError.network("bad URL") }
        var req = URLRequest(url: url)
        // Unique User-Agent is required by Discogs' API policy.
        req.setValue(settings.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// Performs the request (rate-paced) and returns raw data, mapping status codes.
    private func perform(_ request: URLRequest) async throws -> Data {
        await limiter.waitForTurn()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            switch http.statusCode {
            case 200...299: return data
            case 401: throw DiscogsError.missingToken
            case 404: throw DiscogsError.notFound
            case 429: throw DiscogsError.rateLimited
            default: throw DiscogsError.http(http.statusCode)
            }
        } catch let e as DiscogsError {
            throw e
        } catch {
            throw DiscogsError.network(error.localizedDescription)
        }
    }

    // MARK: - Endpoints

    /// Search the database for a release matching this barcode. Works without a
    /// token (25 req/min); a token raises the limit and returns thumbnails.
    func searchByBarcode(_ barcode: String) async throws -> [DiscogsSearchResult] {
        let req = try makeRequest("/database/search", query: [
            URLQueryItem(name: "barcode", value: barcode),
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: "20")
        ])
        let data = try await perform(req)
        let decoded = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
        return decoded.results ?? []
    }

    /// Full metadata for a release.
    func fetchRelease(id: Int) async throws -> (DiscogsRelease, Data) {
        let curr = settings.currency
        let req = try makeRequest("/releases/\(id)", query: [
            URLQueryItem(name: "curr_abbr", value: curr)
        ])
        let data = try await perform(req)
        let decoded = try JSONDecoder().decode(DiscogsRelease.self, from: data)
        return (decoded, data)
    }

    /// Live marketplace floor + count for a release.
    func fetchStats(releaseID: Int) async throws -> DiscogsMarketplaceStats {
        let req = try makeRequest("/marketplace/stats/\(releaseID)", query: [
            URLQueryItem(name: "curr_abbr", value: settings.currency)
        ])
        let data = try await perform(req)
        return try JSONDecoder().decode(DiscogsMarketplaceStats.self, from: data)
    }

    /// Per-condition suggested asking prices. Requires the token account to have
    /// complete seller settings; returns nil (rather than throwing) when the
    /// endpoint is unavailable so valuation can still proceed from stats.
    func fetchPriceSuggestions(releaseID: Int) async -> DiscogsPriceSuggestions? {
        guard settings.hasToken,
              let req = try? makeRequest("/marketplace/price_suggestions/\(releaseID)"),
              let data = try? await perform(req)
        else { return nil }
        return DiscogsPriceSuggestions.parse(data)
    }
}
