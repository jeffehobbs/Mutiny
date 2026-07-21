import Foundation
import AVFoundation
import Vision
import CoreMedia
import Combine
import AppKit

/// Drives an AVCaptureSession over a chosen camera (built-in, external, or an
/// iPhone via Continuity Camera) and emits recognized product barcodes.
///
/// Barcodes are detected with the **Vision** framework rather than
/// `AVCaptureMetadataOutput`: on macOS the metadata output does not support
/// machine-readable-code symbologies (its `availableMetadataObjectTypes` is
/// empty for barcodes), so it never fires. Vision's `VNDetectBarcodesRequest`
/// is fully supported on macOS and reads rotated/partial codes well.
///
/// Optimized for scanning stacks: the same code won't re-fire until it has left
/// the frame for `debounceInterval`, so you can just keep flipping through CDs.
final class BarcodeScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

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
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.jeffhobbs.Mutiny.session")
    private let visionQueue = DispatchQueue(label: "com.jeffhobbs.Mutiny.vision")

    private var recentReads: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 2.5
    private var isProcessingFrame = false

    /// Product-oriented symbologies. Set on the request so we ignore, e.g.,
    /// stray QR codes on packaging. Newer symbologies are added when available.
    private lazy var barcodeRequest: VNDetectBarcodesRequest = {
        let request = VNDetectBarcodesRequest()
        let desired: [VNBarcodeSymbology] = [
            .ean13, .ean8, .upce, .code128, .code39, .code93, .itf14, .i2of5
        ]
        // A fresh request's `symbologies` is the full set supported by this
        // Vision revision; intersect so we never set an unsupported one.
        let supported = Set(request.symbologies)
        request.symbologies = desired.filter { supported.contains($0) }
        return request
    }()

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

        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: visionQueue)
            session.addOutput(videoOutput)
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

    // MARK: - Frame processing (Vision)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Drop frames while a detection is in flight so we don't back up the queue.
        guard !isProcessingFrame else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([barcodeRequest])
        } catch {
            return
        }

        guard let results = barcodeRequest.results else { return }
        for observation in results {
            guard let value = observation.payloadStringValue else { continue }
            emit(value)
        }
    }

    /// Applies debouncing and forwards genuinely-new reads to the main queue.
    private func emit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        if let last = recentReads[trimmed], now.timeIntervalSince(last) < debounceInterval {
            recentReads[trimmed] = now
            return
        }
        recentReads[trimmed] = now
        // Trim stale entries so the map doesn't grow unbounded.
        recentReads = recentReads.filter { now.timeIntervalSince($0.value) < 30 }

        DispatchQueue.main.async {
            self.lastBarcode = trimmed
            self.lastScanAt = now
            self.onBarcode?(trimmed)
        }
    }
}
