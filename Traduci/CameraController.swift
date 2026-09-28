import AVFoundation
import CoreImage
import QuartzCore

/// What the camera saw in one live frame.
struct FrameResult: @unchecked Sendable {
    let entries: [MenuEntry]
    /// Upright (portrait) frame size in pixels.
    let imageSize: CGSize
    let ocrMilliseconds: Double
}

/// A still, read closely: the page in bands, so the small print (prices, allergens) comes out.
struct StillResult: @unchecked Sendable {
    let image: CGImage
    let entries: [MenuEntry]
    /// Paper and ink around each entry's title (same order as `entries`).
    let colors: [InkSampler.Colors?]
    let ocrMilliseconds: Double
}

enum CameraError: LocalizedError {
    case noCamera, cannotAddInput, cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No back camera found."
        case .cannotAddInput: return "The camera is in use by something else."
        case .cannotAddOutput: return "Couldn't read frames from the camera."
        }
    }
}

/// Owns the capture session and reads the newest frame whenever the previous read is done. Frames
/// that arrive while OCR is busy are dropped, never queued, so what it reports is always fresh.
/// Taking a still freezes the newest frame that had text, reads it closely, and pauses until
/// `resume()`: nothing moves while the user reads.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// Called on the frame queue after every live frame.
    var onFrame: (@Sendable (FrameResult) -> Void)?
    /// Called on the frame queue the moment a still is taken, before it's read: freeze on it.
    var onFreeze: (@Sendable (CGImage) -> Void)?
    /// Called on the frame queue when the still has been read.
    var onStill: (@Sendable (StillResult) -> Void)?

    private let sessionQueue = DispatchQueue(label: "Traduci.session")
    private let frameQueue = DispatchQueue(label: "Traduci.frames", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let recognizer = TextRecognizer()
    private let languages = LanguageDetector() // frame queue only
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // Session queue only.
    private var device: AVCaptureDevice?
    private var mainLensZoom: CGFloat = 1
    private var zoomStops: [CGFloat] = [1, 2]

    // Frame queue only.
    private var paused = false
    private var stillRequested = false
    /// The newest frame that had text: a still freezes that one at once instead of waiting.
    private var lastTextFrame: TextFrame?
    private var demoTimer: DispatchSourceTimer?

    private enum Picture {
        case buffer(CVPixelBuffer) // sensor layout: landscape
        case image(CGImage) // already upright (demo mode)
    }

    private struct TextFrame {
        let picture: Picture
        let lines: [OCRLine]
        let time: CFTimeInterval
    }

    /// Starts the camera and returns its zoom stops relative to the main lens, e.g. [1, 2, 5].
    func start() async throws -> [CGFloat] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CGFloat], Error>) in
            sessionQueue.async {
                do {
                    if self.device == nil { try self.configure() }
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume(returning: self.zoomStops)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Demo mode (Simulator screenshots): `image` stands in for the camera, a few frames a second.
    func startDemo(with image: CGImage) {
        frameQueue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.frameQueue)
            timer.schedule(deadline: .now(), repeating: 0.25)
            timer.setEventHandler { [weak self] in
                guard let self, !self.paused else { return }
                self.process(.image(image))
            }
            timer.resume()
            self.demoTimer = timer
        }
    }

    /// Freezes the newest frame that had text (or, with none lately, the next frame), reads it
    /// closely, then stays paused until `resume()`.
    func takeStill() {
        frameQueue.async {
            if let frame = self.lastTextFrame, CACurrentMediaTime() - frame.time < 0.8 {
                self.read(frame.picture, lines: frame.lines)
            } else {
                self.stillRequested = true
            }
        }
    }

    /// Back to reading every frame. Queued behind any pending still, so the two can't cross.
    func resume() {
        frameQueue.async {
            self.paused = false
            self.stillRequested = false
            self.lastTextFrame = nil
        }
    }

    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.device, device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if on {
                    try device.setTorchModeOn(level: 0.8)
                } else {
                    device.torchMode = .off
                }
            } catch {}
        }
    }

    /// `factor` is relative to the main (1×) lens. `smooth` ramps like the Camera app's lens buttons.
    func setZoom(_ factor: CGFloat, smooth: Bool) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            let target = min(max(self.mainLensZoom * factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if smooth {
                device.ramp(toVideoZoomFactor: target, withRate: 6)
            } else {
                device.videoZoomFactor = target
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !paused, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        process(.buffer(pixelBuffer))
    }

    /// Frame queue only.
    private func process(_ picture: Picture) {
        let started = CACurrentMediaTime()
        let lines: [OCRLine]
        switch picture {
        case .buffer(let buffer):
            // Buffers stay in the sensor's landscape layout; `.right` tells Vision the phone is upright.
            lines = recognizer.lines(in: buffer, orientation: .right, fast: false)
        case .image(let image):
            lines = recognizer.lines(in: image, orientation: .up, fast: false)
        }
        let ocrMilliseconds = (CACurrentMediaTime() - started) * 1000
        if stillRequested {
            read(picture, lines: lines)
            return
        }
        let size = uprightSize(picture)
        let entries = MenuReader.entries(from: lines, aspect: size.height / max(size.width, 1), language: languages.language(of:))
        if !entries.isEmpty {
            lastTextFrame = TextFrame(picture: picture, lines: lines, time: CACurrentMediaTime())
        }
        onFrame?(FrameResult(entries: entries, imageSize: size, ocrMilliseconds: ocrMilliseconds))
    }

    /// Frame queue only: freeze on `picture`, then read it in bands for the small print.
    private func read(_ picture: Picture, lines: [OCRLine]) {
        paused = true
        stillRequested = false
        lastTextFrame = nil
        let still: CGImage
        switch picture {
        case .image(let image):
            still = image
        case .buffer(let buffer):
            let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
            guard let image = ciContext.createCGImage(upright, from: upright.extent) else {
                paused = false
                return
            }
            still = image
        }
        onFreeze?(still)

        let started = CACurrentMediaTime()
        let closer = recognizer.lines(in: still, fast: false, bands: 2)
        let merged = OCRTiles.merge([lines, closer])
        let aspect = CGFloat(still.height) / CGFloat(max(still.width, 1))
        let entries = MenuReader.entries(from: merged, aspect: aspect, language: languages.language(of:))
        let sampler = InkSampler(image: still)
        let colors = entries.map { entry in sampler.map { $0.colors(for: entry.titleBox) } }
        onStill?(StillResult(image: still, entries: entries, colors: colors,
                             ocrMilliseconds: (CACurrentMediaTime() - started) * 1000))
    }

    private func uprightSize(_ picture: Picture) -> CGSize {
        switch picture {
        case .buffer(let buffer):
            return CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer))
        case .image(let image):
            return CGSize(width: image.width, height: image.height)
        }
    }

    // MARK: - Setup

    private func configure() throws {
        guard let device = Self.backCamera() else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        // 1080p: Vision reads at a fixed working size anyway (a 4K frame finds nothing more), and
        // a still is read again in bands for the small print.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }

        if (try? device.lockForConfiguration()) != nil {
            tune(device)
            device.unlockForConfiguration()
        }
        self.device = device
    }

    private func tune(_ device: AVCaptureDevice) {
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = false // snappier refocus; smoothing is for filming
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isLowLightBoostSupported {
            device.automaticallyEnablesLowLightBoostWhenAvailable = true
        }
        // Multi-lens virtual devices start on the ultra-wide at zoom 1.0. Start on the main lens like
        // the Camera app; the device still hops to the ultra-wide for macro when text is very close.
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        if device.constituentDevices.first?.deviceType == .builtInUltraWideCamera, let mainLens = switchOvers.first {
            mainLensZoom = mainLens
        }
        // 1×, 2× (sensor crop), and the telephoto lens when there is one (5× on Pro iPhones).
        if let telephoto = switchOvers.last.map({ $0 / mainLensZoom }), telephoto > 2.5 {
            zoomStops = [1, 2, telephoto]
        }
        device.videoZoomFactor = min(max(mainLensZoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private static func backCamera() -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        for type in preferred {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return nil
    }
}
