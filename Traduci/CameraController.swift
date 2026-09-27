import AVFoundation
import CoreImage
import QuartzCore

struct FrameResult: @unchecked Sendable {
    let blocks: [TextBlock]
    /// Upright (portrait) frame size in pixels.
    let imageSize: CGSize
    let ocrMilliseconds: Double
    /// The exact frame the blocks came from; only set when a still was requested.
    let snapshot: CGImage?
    /// Paper and ink around each block, sampled from the still (same order as `blocks`).
    let colors: [InkSampler.Colors]?
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

/// Owns the capture session and runs OCR on the newest frame whenever the previous pass is done.
/// Frames that arrive while OCR is busy are dropped, never queued, so results are always fresh.
/// While the user reads a still, it only glances now and then, to notice when the page changes.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// Called on the frame queue after every processed frame.
    var onFrame: (@Sendable (FrameResult) -> Void)?

    private let sessionQueue = DispatchQueue(label: "Traduci.session")
    private let frameQueue = DispatchQueue(label: "Traduci.frames", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let recognizer = TextRecognizer()
    private let languages = LanguageDetector() // frame queue only
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // Session queue only.
    private var device: AVCaptureDevice?
    /// Read on the frame queue, to take stills only once autofocus has settled.
    private weak var focusDevice: AVCaptureDevice?
    private var mainLensZoom: CGFloat = 1
    private var zoomStops: [CGFloat] = [1, 2]

    private let lock = NSLock()
    private var _fastOCR = false
    private var _stillRequested = false
    private var _stillRequestedAt: CFTimeInterval = 0
    private var _checkInterval: CFTimeInterval = 0 // 0: every frame; while reading, an occasional glance
    private var _lastProcessed: CFTimeInterval = 0

    var fastOCR: Bool {
        get { locked { _fastOCR } }
        set { locked { _fastOCR = newValue } }
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

    /// Delivers the next sharp frame as a still, then only glances at the camera until `resume()`.
    func takeStill() {
        locked {
            _stillRequested = true
            _stillRequestedAt = CACurrentMediaTime()
        }
    }

    /// Back to reading every frame.
    func resume() {
        locked {
            _stillRequested = false
            _checkInterval = 0
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
        let now = CACurrentMediaTime()
        let (fast, wantsStill, requestedAt, interval, last) = locked { (_fastOCR, _stillRequested, _stillRequestedAt, _checkInterval, _lastProcessed) }
        guard wantsStill || now - last >= interval, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        locked { _lastProcessed = now }

        let started = CACurrentMediaTime()
        // Buffers stay in the sensor's landscape layout; `.right` tells Vision the phone is held upright.
        let lines = recognizer.lines(in: pixelBuffer, orientation: .right, fast: fast)
        let ocrMilliseconds = (CACurrentMediaTime() - started) * 1000
        let aspect = CGFloat(CVPixelBufferGetWidth(pixelBuffer)) / CGFloat(CVPixelBufferGetHeight(pixelBuffer)) // upright height ÷ width
        let blocks = TextBlockBuilder.blocks(from: lines, aspect: aspect, language: languages.language(of:))

        var snapshot: CGImage?
        var colors: [InkSampler.Colors]?
        // A still only once autofocus has settled (or half a second has passed), so it reads sharply.
        if wantsStill, !(focusDevice?.isAdjustingFocus ?? false) || now - requestedAt > 0.5 {
            let upright = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            if let still = ciContext.createCGImage(upright, from: upright.extent) {
                let stillWanted = locked { () -> Bool in
                    guard _stillRequested else { return false } // back to aiming while we were busy
                    _stillRequested = false
                    _checkInterval = 0.7
                    return true
                }
                if stillWanted {
                    snapshot = still
                    colors = InkSampler(image: still).map { sampler in blocks.map { sampler.colors(for: $0.box) } }
                }
            }
        }

        let uprightSize = CGSize(width: CVPixelBufferGetHeight(pixelBuffer), height: CVPixelBufferGetWidth(pixelBuffer))
        onFrame?(FrameResult(blocks: blocks, imageSize: uprightSize, ocrMilliseconds: ocrMilliseconds, snapshot: snapshot, colors: colors))
    }

    // MARK: - Setup

    private func configure() throws {
        guard let device = Self.backCamera() else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        // 1080p: sharp enough for menu text, light enough for OCR to keep up.
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
        focusDevice = device
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

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
