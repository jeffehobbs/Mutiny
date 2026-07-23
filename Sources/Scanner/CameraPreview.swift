import SwiftUI
import AVFoundation
import AppKit

/// SwiftUI wrapper around an AVCaptureVideoPreviewLayer.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        applyMirroring(to: view.previewLayer)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        applyMirroring(to: nsView.previewLayer)
    }

    /// Horizontally flip the *preview* so it reads like a mirror. This affects
    /// only the on-screen display; barcode detection runs off a separate
    /// AVCaptureVideoDataOutput sample buffer and is unaffected.
    private func applyMirroring(to previewLayer: AVCaptureVideoPreviewLayer) {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if !connection.isVideoMirrored {
            connection.isVideoMirrored = true
        }
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.frame = bounds
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
