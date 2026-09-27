import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Aim, then read. While the phone moves, the camera is live and clean; translation runs ahead in
/// the background. The moment the phone is held still, a sharp still is locked and the English is
/// laid over it, so nothing moves while you read. Move on and it goes back to aiming by itself.
@MainActor
@Observable
final class AppModel {
    enum CameraState: Equatable {
        case starting
        case running
        case denied
        case unavailable(String)
    }

    enum Mode: Equatable {
        case aiming
        case reading
    }

    // Tuning. Hand tremor while reading stays well under these; a deliberate move doesn't.
    private static let steadyBeforeLock: TimeInterval = 0.3
    private static let turnToUnlock = 8.0 // degrees from where the still was taken
    private static let turnToRearm = 4.0 // degrees after going back to aiming by hand
    private static let maxStillZoom: CGFloat = 4

    let engine = TranslationEngine()
    let camera = CameraController()
    private let motion = MotionMonitor()

    private(set) var cameraState: CameraState = .starting
    private(set) var mode: Mode = .aiming
    private(set) var isLocking = false
    /// Italian text in view right now (aiming): the hint says "Hold steady".
    private(set) var textInView = false
    private(set) var stillImage: CGImage?
    private(set) var captions: [Caption] = []
    private(set) var stillZoom: CGFloat = 1
    private(set) var stillPan: CGSize = .zero
    private(set) var imageSize = CGSize(width: 1080, height: 1920)
    private(set) var ocrMilliseconds: Double?
    private(set) var torchOn = false
    private(set) var fastOCR = false
    private(set) var zoom: CGFloat = 1
    /// Lens stops the zoom button cycles through, relative to the main lens.
    private(set) var zoomStops: [CGFloat] = [1, 2]

    var fastOCRAvailable: Bool { TextRecognizer.fastModeAvailable }
    /// While a translation's detail sheet is open, moving the phone doesn't unlock the still.
    var isShowingDetail = false

    /// Size of the full-screen viewfinder.
    @ObservationIgnored var viewSize: CGSize = .zero
    /// Off after going back to aiming by hand, until the phone moves: no snapping straight back.
    @ObservationIgnored private var autoLockArmed = true

    init() {
        engine.onTranslation = { [weak self] source, translation in
            self?.didTranslate(source, to: translation)
        }
        camera.onFrame = { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async { // strictly in frame order
                MainActor.assumeIsolated { self.handleFrame(result) }
            }
        }
        motion.onReading = { [weak self] reading in
            MainActor.assumeIsolated { self?.handleMotion(reading) } // delivered on the main queue
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
            motion.start()
        } catch {
            cameraState = .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Aim and read

    /// The big button: read what's in view now, or go back to aiming.
    func toggleLock() {
        if mode == .reading || isLocking {
            unlock(byHand: true)
        } else {
            lock()
        }
    }

    private func lock() {
        guard mode == .aiming, !isLocking else { return }
        isLocking = true
        camera.takeStill()
    }

    private func unlock(byHand: Bool) {
        isLocking = false
        mode = .aiming
        stillImage = nil
        captions = []
        stillZoom = 1
        stillPan = .zero
        camera.resume()
        if byHand {
            autoLockArmed = false
            motion.mark()
        }
    }

    private func handleFrame(_ result: FrameResult) {
        imageSize = result.imageSize
        ocrMilliseconds = result.ocrMilliseconds
        let visible = AspectFillMapper(imageSize: result.imageSize, viewSize: viewSize).visibleRect
        var blocks: [TextBlock] = []
        var colors: [InkSampler.Colors?] = []
        for (index, block) in result.blocks.enumerated() where visible.contains(CGPoint(x: block.box.midX, y: block.box.midY)) {
            blocks.append(block)
            colors.append(result.colors?[index])
        }

        if let still = result.snapshot {
            guard isLocking else { return } // went back to aiming before the still arrived
            isLocking = false
            guard !blocks.isEmpty else { // the text left the frame; keep aiming
                camera.resume()
                return
            }
            stillImage = still
            captions = zip(blocks, colors).map { block, color in
                Caption(block: block, translation: engine.cache[block.text], colors: color)
            }
            mode = .reading
            motion.mark()
            engine.request(Captions.priority(blocks))
            return
        }

        switch mode {
        case .aiming:
            textInView = !blocks.isEmpty
            engine.request(Captions.priority(blocks)) // translate ahead, so reading starts translated
        case .reading:
            if Captions.sceneChanged(from: captions, to: blocks) {
                unlock(byHand: false) // slid on to other text without turning much
            }
        }
    }

    private func handleMotion(_ reading: MotionMonitor.Reading) {
        switch mode {
        case .aiming:
            if !autoLockArmed, reading.degreesFromMark > Self.turnToRearm || reading.movedSharply {
                autoLockArmed = true
            }
            if autoLockArmed, textInView, !isLocking, reading.steadyFor >= Self.steadyBeforeLock {
                lock()
            }
        case .reading:
            guard !isShowingDetail else { return }
            if reading.degreesFromMark > Self.turnToUnlock || reading.movedSharply {
                unlock(byHand: false)
            }
        }
    }

    private func didTranslate(_ source: String, to translation: String) {
        for index in captions.indices where captions[index].source == source {
            captions[index].translation = translation
        }
    }

    // MARK: - Reading a still

    /// Pinch on the still: zoom about the middle of the screen.
    func zoomStill(to zoom: CGFloat, from start: (zoom: CGFloat, pan: CGSize)) {
        let clamped = min(max(zoom, 1), Self.maxStillZoom)
        let ratio = clamped / max(start.zoom, 1)
        stillZoom = clamped
        stillPan = stillMapper.clamped(CGSize(width: start.pan.width * ratio, height: start.pan.height * ratio))
    }

    func panStill(to pan: CGSize) {
        stillPan = stillMapper.clamped(pan)
    }

    private var stillMapper: AspectFillMapper {
        AspectFillMapper(imageSize: imageSize, viewSize: viewSize, zoom: stillZoom)
    }

    // MARK: - Camera controls

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
}
