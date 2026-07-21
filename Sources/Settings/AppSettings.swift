import Foundation
import Combine

/// App-wide preferences, persisted in UserDefaults. Observable so views update
/// live when the token / user-agent / currency change.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let token = "discogsToken"
        static let userAgent = "discogsUserAgent"
        static let currency = "currency"
        static let installID = "installID"
        static let playSound = "playSoundOnScan"
        static let autoAddSingleResult = "autoAddSingleResult"
    }

    private let defaults = UserDefaults.standard

    @Published var discogsToken: String {
        didSet { defaults.set(discogsToken, forKey: Key.token) }
    }

    /// Discogs requires a *unique* User-Agent per application. We seed a unique
    /// default (with a per-install id) but the user can override it in Settings.
    @Published var userAgent: String {
        didSet { defaults.set(userAgent, forKey: Key.userAgent) }
    }

    @Published var currency: String {
        didSet { defaults.set(currency, forKey: Key.currency) }
    }

    @Published var playSoundOnScan: Bool {
        didSet { defaults.set(playSoundOnScan, forKey: Key.playSound) }
    }

    @Published var autoAddSingleResult: Bool {
        didSet { defaults.set(autoAddSingleResult, forKey: Key.autoAddSingleResult) }
    }

    /// Stable per-install identifier used to make the default user-agent unique.
    let installID: String

    private init() {
        // Stable install id.
        if let existing = defaults.string(forKey: Key.installID) {
            installID = existing
        } else {
            let generated = String(UUID().uuidString.prefix(8)).lowercased()
            defaults.set(generated, forKey: Key.installID)
            installID = generated
        }

        discogsToken = defaults.string(forKey: Key.token) ?? ""
        currency = defaults.string(forKey: Key.currency) ?? "USD"
        playSoundOnScan = defaults.object(forKey: Key.playSound) as? Bool ?? true
        autoAddSingleResult = defaults.object(forKey: Key.autoAddSingleResult) as? Bool ?? true

        let defaultUA = "Mutiny/1.0 +macos (scan-\(installID))"
        userAgent = defaults.string(forKey: Key.userAgent) ?? defaultUA
    }

    /// Supported marketplace currencies per Discogs.
    static let currencies = ["USD", "GBP", "EUR", "CAD", "AUD", "JPY", "CHF", "MXN", "BRL", "NZD", "SEK", "ZAR"]

    var hasToken: Bool { !discogsToken.trimmingCharacters(in: .whitespaces).isEmpty }
}
