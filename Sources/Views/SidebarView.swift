import SwiftUI

/// Left column: live scanner + category filters + manual entry + activity feed.
struct SidebarView: View {
    @ObservedObject var scanner: BarcodeScanner
    @ObservedObject var engine: ImportEngine
    @Binding var categoryFilter: MediaCategory?
    @Binding var manualBarcode: String
    let counts: [MediaCategory: Int]

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                scannerSection
                Divider()
                manualSection
                Divider()
                filterSection
                Divider()
                activitySection
            }
            .padding(12)
        }
        .background(.background)
    }

    // MARK: - Scanner

    private var scannerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Scanner", systemImage: "barcode.viewfinder")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black)
                if scanner.isRunning {
                    CameraPreview(session: scanner.session)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    ScanReticle()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash")
                            .font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                        Text("Camera off").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .frame(height: 170)
            .overlay(alignment: .bottomLeading) { scanStatusPill.padding(6) }

            if !scanner.availableCameras.isEmpty {
                Picker("Camera", selection: $scanner.selectedCameraID) {
                    ForEach(scanner.availableCameras) { cam in
                        Text(cam.isContinuity ? "📱 \(cam.name)" : cam.name)
                            .tag(Optional(cam.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack {
                Button {
                    scanner.isRunning ? scanner.stop() : scanner.start()
                } label: {
                    Label(scanner.isRunning ? "Stop Scanning" : "Start Scanning",
                          systemImage: scanner.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(scanner.isRunning ? .red : .accentColor)

                Button {
                    scanner.refreshCameras()
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan for cameras (e.g. after connecting an iPhone)")
            }

            if !settings.hasToken {
                Label("Works now. Add a Discogs token in Settings (⌘,) for higher rate limits and per-condition prices.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = scanner.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var scanStatusPill: some View {
        Group {
            switch engine.status {
            case .idle:
                EmptyView()
            case .working(let barcode):
                pill("Looking up \(barcode)…", .blue, spinning: true)
            case .added(let title):
                pill("Added \(title)", .green)
            case .updated(let title):
                pill("Updated \(title)", .teal)
            case .duplicateSkipped(let title):
                pill("Already have \(title)", .gray)
            case .failed(_, let message):
                pill(message, .red)
            }
        }
    }

    private func pill(_ text: String, _ color: Color, spinning: Bool = false) -> some View {
        HStack(spacing: 5) {
            if spinning { ProgressView().controlSize(.small).tint(.white) }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.9), in: Capsule())
    }

    // MARK: - Manual entry

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Enter barcode", systemImage: "keyboard")
                .font(.subheadline.weight(.semibold))
            HStack {
                TextField("UPC / EAN", text: $manualBarcode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitManual)
                Button("Add", action: submitManual)
                    .disabled(manualBarcode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submitManual() {
        let code = manualBarcode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        engine.lookup(barcode: code)
        manualBarcode = ""
    }

    // MARK: - Filters

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Library", systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 4)
            filterRow(title: "All Media", symbol: "tray.full", category: nil,
                      count: counts.values.reduce(0, +))
            ForEach(MediaCategory.allCases) { cat in
                filterRow(title: cat.rawValue, symbol: cat.symbol, category: cat,
                          count: counts[cat] ?? 0)
            }
        }
    }

    private func filterRow(title: String, symbol: String, category: MediaCategory?, count: Int) -> some View {
        Button {
            categoryFilter = category
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(categoryFilter == category ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Recent activity", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
            if engine.recent.isEmpty {
                Text("Scanned items will appear here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(engine.recent.prefix(12).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Animated targeting reticle overlaid on the live preview.
struct ScanReticle: View {
    @State private var pulse = false
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * 0.7
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.green.opacity(pulse ? 0.9 : 0.4), lineWidth: 2)
                .frame(width: w, height: 60)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        }
        .allowsHitTesting(false)
        .onAppear { pulse = true }
    }
}
