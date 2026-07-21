import Foundation
import AVFoundation
import Combine
import AppKit

/// Drives an AVCaptureSession over a chosen camera (built-in, external, or an
/// iPhone via Continuity Camera) and emits recognized product barcodes.
/// Optimized for scanning stacks: the same code won't re-fire until it has left
/// the frame for `debounceInterval`, so you can just keep flipping through CDs.
final class BarcodeScanner: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {

    struct CameraDevice: Identifiable, Hashable {
        let id: String
        let name: String
        let isContinuity: Bool
    }

    @Published var availableCameras: [CameraDevice] = []
    @Published var selectedCameraID: String? {
        didSet {
            if oldValue != selectedCameraID, isRunning { restart() }
        }
    }
    @Published var isRunning = false
    @Published var isAuthorized = false
    @Published var lastBarcode: String = ""
    @Published var lastScanAt: Date?
    @Published var errorMessage: String?

    /// Called on the main queue for each *newly* recognized barcode.
    var onBarcode: ((String) -> Void)?

    let session = AVCaptureSession()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "com.jeffhobbs.Shelf.session")

    private var recentReads: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 2.5

    private let barcodeTypes: [AVMetadataObject.ObjectType] = [
        .ean13, .ean8, .upce, .code128, .code39, .code93, .itf14, .interleaved2of5
    ]

    override init() {
        super.init()
        refreshCameras()
    }

    // MARK: - Permissions

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.isAuthorized = granted
                    completion(granted)
                }
            }
        default:
            isAuthorized = false
            completion(false)
        }
    }

    // MARK: - Camera discovery

    func refreshCameras() {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) {
            types.append(.continuityCamera)
            types.append(.deskViewCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        let cams = discovery.devices.map { device -> CameraDevice in
            let isContinuity: Bool
            if #available(macOS 14.0, *) {
                isContinuity = device.deviceType == .continuityCamera
            } else {
                isContinuity = device.localizedName.localizedCaseInsensitiveContains("iphone")
            }
            return CameraDevice(id: device.uniqueID, name: device.localizedName, isContinuity: isContinuity)
        }
        DispatchQueue.main.async {
            self.availableCameras = cams
            if self.selectedCameraID == nil {
                // Prefer a Continuity iPhone if present (best macro focus for small barcodes).
                self.selectedCameraID = cams.first(where: { $0.isContinuity })?.id ?? cams.first?.id
            }
        }
    }

    // MARK: - Session control

    func start() {
        requestAccess { granted in
            guard granted else {
                self.errorMessage = "Camera access denied. Enable it in System Settings ▸ Privacy & Security ▸ Camera."
                return
            }
            self.sessionQueue.async { self.configureAndRun() }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func restart() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.configureAndRun()
        }
    }

    private func configureAndRun() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // Clear existing inputs/outputs.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = resolveDevice() else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorMessage = "No camera available." }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { self.errorMessage = "Couldn't open camera: \(error.localizedDescription)" }
            return
        }

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: sessionQueue)
            let supported = metadataOutput.availableMetadataObjectTypes
            metadataOutput.metadataObjectTypes = barcodeTypes.filter { supported.contains($0) }
        }

        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async {
            self.isRunning = true
            self.errorMessage = nil
        }
    }

    private func resolveDevice() -> AVCaptureDevice? {
        if let id = selectedCameraID,
           let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .video)
    }

    // MARK: - Delegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue else { continue }
            let now = Date()
            if let last = recentReads[value], now.timeIntervalSince(last) < debounceInterval {
                recentReads[value] = now
                continue
            }
            recentReads[value] = now
            // Trim stale entries so the map doesn't grow unbounded.
            recentReads = recentReads.filter { now.timeIntervalSince($0.value) < 30 }

            DispatchQueue.main.async {
                self.lastBarcode = value
                self.lastScanAt = now
                self.onBarcode?(value)
            }
        }
    }
}
