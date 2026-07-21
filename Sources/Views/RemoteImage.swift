import SwiftUI
import AppKit

/// Loads and caches cover art from Discogs. Uses a custom loader because
/// Discogs image hosts require the same unique User-Agent as the API, which
/// SwiftUI's AsyncImage can't set.
actor ImageCache {
    static let shared = ImageCache()
    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    func image(for urlString: String, userAgent: String) async -> NSImage? {
        if let cached = cache[urlString] { return cached }
        if let task = inFlight[urlString] { return await task.value }

        let task = Task<NSImage?, Never> {
            guard let url = URL(string: urlString) else { return nil }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let image = NSImage(data: data) else { return nil }
            return image
        }
        inFlight[urlString] = task
        let result = await task.value
        inFlight[urlString] = nil
        if let result { cache[urlString] = result }
        return result
    }

    func clear() { cache.removeAll() }
}

struct RemoteImage: View {
    let urlString: String
    var cornerRadius: CGFloat = 6
    @EnvironmentObject private var settings: AppSettings
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: urlString) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: failed ? "questionmark.square.dashed" : "opticaldisc")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func load() async {
        guard !urlString.isEmpty else { failed = true; return }
        let loaded = await ImageCache.shared.image(for: urlString, userAgent: settings.userAgent)
        await MainActor.run {
            self.image = loaded
            self.failed = (loaded == nil)
        }
    }
}
