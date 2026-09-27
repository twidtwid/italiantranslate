import AVFoundation
import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum CameraState: Equatable {
        case starting
        case running
        case denied
        case unavailable(String)
    }

    let engine = TranslationEngine()
    let camera = CameraController()

    private(set) var cameraState: CameraState = .starting
    private(set) var items: [OverlayItem] = []
    private(set) var imageSize = CGSize(width: 1080, height: 1920)
    private(set) var ocrMilliseconds: Double?
    private(set) var frozenImage: CGImage?
    private(set) var isFreezePending = false
    private(set) var torchOn = false
    private(set) var fastOCR = false
    private(set) var zoom: CGFloat = 1

    var isFrozen: Bool { frozenImage != nil }
    var fastOCRAvailable: Bool { TextRecognizer.fastModeAvailable }

    /// Size of the full-screen viewfinder; text cropped out of view is ignored.
    @ObservationIgnored var viewSize: CGSize = .zero
    @ObservationIgnored private var tracker = OverlayTracker()

    init() {
        engine.onTranslation = { [weak self] source, translation in
            self?.didTranslate(source, to: translation)
        }
        camera.onFrame = { [weak self] result in
            guard let self else { return }
            Task { @MainActor in self.handle(result) }
        }
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                cameraState = .denied
                return
            }
        default:
            cameraState = .denied
            return
        }
        do {
            try await camera.start()
            cameraState = .running
        } catch {
            cameraState = .unavailable(error.localizedDescription)
        }
    }

    func toggleFreeze() {
        if isFrozen || isFreezePending {
            frozenImage = nil
            isFreezePending = false
            camera.resume()
        } else {
            isFreezePending = true
            camera.freezeNextFrame()
        }
    }

    func toggleTorch() {
        torchOn.toggle()
        camera.setTorch(torchOn)
    }

    /// iOS switches the torch off in the background; keep the button honest.
    func didEnterBackground() {
        torchOn = false
    }

    func toggleFastOCR() {
        fastOCR.toggle()
        camera.fastOCR = fastOCR
    }

    func setZoom(_ factor: CGFloat) {
        zoom = min(max(factor, 1), 8)
        camera.setZoom(zoom)
    }

    private func handle(_ result: FrameResult) {
        guard !isFrozen else { return }
        if result.snapshot != nil, !isFreezePending { return } // resumed before the still arrived

        let now = ProcessInfo.processInfo.systemUptime
        imageSize = result.imageSize
        ocrMilliseconds = result.ocrMilliseconds

        let visible = AspectFillMapper(imageSize: result.imageSize, viewSize: viewSize).visibleRect
        let blocks = result.blocks.filter { visible.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
        tracker.update(with: blocks, at: now, exact: result.snapshot != nil, translations: engine.cache)
        if let snapshot = result.snapshot {
            frozenImage = snapshot
            isFreezePending = false
        }
        items = tracker.items
        engine.request(tracker.sourcesByPriority(seenAt: now))
    }

    private func didTranslate(_ source: String, to translation: String) {
        tracker.apply(translation: translation, for: source)
        items = tracker.items
    }
}
