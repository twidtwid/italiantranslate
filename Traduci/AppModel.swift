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
    /// Lens stops the zoom button cycles through, relative to the main lens.
    private(set) var zoomStops: [CGFloat] = [1, 2]

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
            DispatchQueue.main.async { // strictly in frame order
                MainActor.assumeIsolated { self.handle(result) }
            }
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
            zoomStops = try await camera.start()
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

    func setZoom(_ factor: CGFloat, smooth: Bool = false) {
        zoom = min(max(factor, 1), 10)
        camera.setZoom(zoom, smooth: smooth)
    }

    /// 1× → 2× → telephoto → 1×, like the Camera app's lens button.
    func cycleZoom() {
        setZoom(zoomStops.first { $0 > zoom + 0.05 } ?? 1, smooth: true)
    }

    private func handle(_ result: FrameResult) {
        guard !isFrozen else { return }
        if result.snapshot != nil, !isFreezePending { return } // resumed before the still arrived

        let now = ProcessInfo.processInfo.systemUptime
        imageSize = result.imageSize
        ocrMilliseconds = result.ocrMilliseconds
        if result.imageSize.width > 0 {
            tracker.imageAspect = result.imageSize.height / result.imageSize.width
        }

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
