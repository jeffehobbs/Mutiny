import SwiftUI
import SwiftData

/// The "shelf": a wall of cover art à la Delicious Library. Big, tappable,
/// value-labeled tiles on a warm wood-toned backdrop.
struct ShelfGridView: View {
    let items: [MediaItem]
    @Binding var selection: UUID?
    @EnvironmentObject private var settings: AppSettings

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20)]

    var body: some View {
        ZStack {
            shelfBackground
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(items) { item in
                            CoverTile(item: item, isSelected: selection == item.id)
                                .onTapGesture { selection = item.id }
                        }
                    }
                    .padding(24)
                }
            }
        }
    }

    private var shelfBackground: some View {
        LinearGradient(
            colors: [Color(red: 0.20, green: 0.13, blue: 0.08),
                     Color(red: 0.11, green: 0.07, blue: 0.05)],
            startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.white.opacity(0.5))
            Text("Point the camera at a barcode")
                .font(.title3.weight(.medium)).foregroundStyle(.white.opacity(0.85))
            Text("CDs, cassettes and records land here the moment they're scanned.")
                .font(.callout).foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

/// A single cover with its own little wooden shelf lip and a value tag.
struct CoverTile: View {
    let item: MediaItem
    let isSelected: Bool
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            RemoteImage(urlString: item.coverURL.isEmpty ? item.thumbURL : item.coverURL)
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 6)
                .overlay(alignment: .topTrailing) { badges }
                .overlay(alignment: .bottomLeading) { valueTag }

            shelfLip

            VStack(spacing: 1) {
                Text(item.title).font(.caption.weight(.semibold))
                    .foregroundStyle(.white).lineLimit(1)
                Text(item.artist).font(.caption2)
                    .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            .frame(width: 150)
            .padding(.top, 5)
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .help("\(item.title) — \(item.artist)")
    }

    private var badges: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Image(systemName: item.category.symbol)
                .font(.caption2.weight(.bold))
                .padding(4)
                .background(.black.opacity(0.55), in: Circle())
                .foregroundStyle(.white)
            if item.quantity > 1 {
                Text("×\(item.quantity)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(5)
    }

    private var valueTag: some View {
        Text(item.displayValue)
            .font(.caption2.weight(.bold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
    }

    /// Little wooden ledge beneath each cover.
    private var shelfLip: some View {
        LinearGradient(colors: [Color(red: 0.42, green: 0.28, blue: 0.16),
                                Color(red: 0.28, green: 0.18, blue: 0.10)],
                       startPoint: .top, endPoint: .bottom)
            .frame(width: 168, height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 3)
            .padding(.top, 4)
    }
}
