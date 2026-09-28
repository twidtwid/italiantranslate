import AVFoundation
import CoreImage
import os
import QuartzCore

/// What the camera saw in one live frame.
struct FrameResult: @unchecked Sendable {
    let entries: [MenuEntry]
    /// Upright (portrait) frame size in pixels.
    let imageSize: CGSize
    let ocrMilliseconds: Double
}

/// A still, read twice: at once from the frame's own reading, so the list shows up with the
/// picture, then closely in bands, so the small print (prices, allergens) comes out.
struct StillResult: @unchecked Sendable {
    let image: CGImage
    let entries: [MenuEntry]
    /// Paper and ink around each entry's title (same order as `entries`).
    let colors: [InkSampler.Colors?]
    /// The close reading: nothing more is coming for this picture.
    let isFinal: Bool
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
/// Taking a still freezes the recent frame that read best, reads it closely, and pauses until
/// `resume()`: nothing moves while the user reads.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// Called on the frame queue after every live frame.
    var onFrame: (@Sendable (FrameResult) -> Void)?
    /// Called on the frame queue the moment a still is taken, before it's read: freeze on it.
    var onFreeze: (@Sendable (CGImage) -> Void)?
    /// Called on the frame queue with the still's first reading, then again with the close one.
    var onStill: (@Sendable (StillResult) -> Void)?
    /// Called on the main queue when the camera stops for the system (a call, another app, the
    /// phone too warm), with what to tell the user; with nil when it's back.
    var onInterruption: (@Sendable (String?) -> Void)?

    private let sessionQueue = DispatchQueue(label: "Traduci.session")
    private let frameQueue = DispatchQueue(label: "Traduci.frames", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let recognizer = TextRecognizer()
    private let languages = LanguageDetector() // frame queue only
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let log = Logger(subsystem: "Traduci", category: "camera")

    /// What the watchdog needs to know about the frame queue, from any queue.
    private struct Health {
        /// When the camera last delivered a frame, read or not.
        var lastArrival: CFTimeInterval = 0
        /// When the OCR read in progress started; nil when none is.
        var busySince: CFTimeInterval?
        var dropped = 0
    }
    private let health = OSAllocatedUnfairLock(initialState: Health())

    // Session queue only.
    private var device: AVCaptureDevice?
    private var mainLensZoom: CGFloat = 1
    private var zoomStops: [CGFloat] = [1, 2]

    private var observers: [NSObjectProtocol] = [] // set once, when the session is configured

    // Frame queue only.
    private var paused = false
    private var stillRequested = false
    /// The recent frame that read best: a still freezes that one at once instead of waiting. In a
    /// moving car or a shaky hand, that's the sharpest of the last moments, not just the last.
    private var bestTextFrame: TextFrame?
    private var lastRead: CFTimeInterval = 0
    /// When a frame last had text in it: with none for a while, frames are read less often.
    private var lastTextSeen = CACurrentMediaTime()
    private var demoTimer: DispatchSourceTimer?

    private enum Picture {
        case buffer(CVPixelBuffer) // sensor layout: landscape
        case image(CGImage) // already upright (demo mode)
    }

    private struct TextFrame {
        let picture: Picture
        let lines: [OCRLine]
        let time: CFTimeInterval
        /// How much it read, and how surely: blur costs letters and confidence.
        let score: Double
    }

    /// How long a frame stays fresh enough to freeze.
    private static let stillWindow: CFTimeInterval = 0.8

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

    /// Freezes the recent frame that read best (or, with none lately, the next frame), reads it
    /// closely, then stays paused until `resume()`.
    func takeStill() {
        frameQueue.async {
            if let frame = self.bestTextFrame, CACurrentMediaTime() - frame.time < Self.stillWindow {
                self.read(frame.picture, lines: frame.lines)
            } else {
                self.paused = false // the next frame is the still: it has to be read
                self.stillRequested = true
            }
        }
    }

    /// Back to reading every frame. Queued behind any pending still, so the two can't cross.
    func resume() {
        frameQueue.async {
            self.paused = false
            self.stillRequested = false
            self.bestTextFrame = nil
            self.lastTextSeen = CACurrentMediaTime() // back to the camera: there's text to read next
        }
    }

    /// A still is overdue. A read may be stuck, or frames may have stopped coming while the preview
    /// runs on: cancel a read that has run for seconds, restart a camera that has gone quiet, and
    /// let frames through again. A pending still stays pending: the next frame read is the picture.
    func recover() {
        let now = CACurrentMediaTime()
        if let since = health.withLock({ $0.busySince }), now - since > 1.5 {
            Self.log.error("OCR stuck for \(now - since, format: .fixed(precision: 1)) s: cancelled")
            recognizer.cancel()
        }
        frameQueue.async { self.paused = false }
        sessionQueue.async {
            guard self.device != nil else { return }
            let quiet = CACurrentMediaTime() - self.health.withLock { $0.lastArrival } > 1
            guard quiet || !self.session.isRunning else { return }
            Self.log.error("No frames for over a second (running: \(self.session.isRunning)): restarting the camera")
            if self.session.isRunning { self.session.stopRunning() }
            self.session.startRunning()
        }
    }

    /// Short exposures while the phone shakes (a moving car, a walk): grainier frames, but sharp
    /// enough to read. Off, the camera goes back to its own judgement, low-light boost included.
    func setShortExposure(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if on {
                let format = device.activeFormat
                let limit = CMTimeMinimum(CMTimeMaximum(CMTime(value: 1, timescale: 125), format.minExposureDuration),
                                          format.maxExposureDuration)
                device.activeMaxExposureDuration = limit
            } else {
                device.activeMaxExposureDuration = .invalid // the format's default
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = !on // the boost lengthens exposures
            }
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
        health.withLock { $0.lastArrival = now }
        guard !paused, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !stillRequested, now - lastRead < restBetweenReads(now) { return }
        lastRead = now
        process(.buffer(pixelBuffer))
    }

    /// Late frames are dropped all the time, by design: OCR is slower than the camera. Any other
    /// reason (out of buffers, a discontinuity) is worth a line in the log.
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        guard reason != (kCMSampleBufferDroppedFrameReason_FrameWasLate as String) else { return }
        let count = health.withLock { health -> Int in
            health.dropped += 1
            return health.dropped
        }
        if count == 1 || count % 30 == 0 {
            Self.log.error("Frame dropped (\(count) so far): \(reason ?? "no reason", privacy: .public)")
        }
    }

    /// Reading every frame is the hardest work the phone does here. Full speed while there's text
    /// in view; less often after a while with none (the phone on the table), in Low Power Mode, and
    /// when the phone runs hot (a sunny terrace), rather than have the system stop the camera.
    private func restBetweenReads(_ now: CFTimeInterval) -> CFTimeInterval {
        var rest: CFTimeInterval = now - lastTextSeen > 2 ? 0.2 : 0
        if ProcessInfo.processInfo.isLowPowerModeEnabled { rest = max(rest, 0.15) }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: rest = max(rest, 0.6)
        case .critical: rest = max(rest, 1.5)
        default: break
        }
        return rest
    }

    /// Frame queue only: an OCR read, marked busy for the watchdog.
    private func reading(_ read: () -> [OCRLine]) -> [OCRLine] {
        health.withLock { $0.busySince = CACurrentMediaTime() }
        defer { health.withLock { $0.busySince = nil } }
        return read()
    }

    /// Frame queue only.
    private func process(_ picture: Picture) {
        let started = CACurrentMediaTime()
        let lines: [OCRLine]
        switch picture {
        case .buffer(let buffer):
            // Buffers stay in the sensor's landscape layout; `.right` tells Vision the phone is upright.
            lines = reading { recognizer.lines(in: buffer, orientation: .right) }
        case .image(let image):
            lines = reading { recognizer.lines(in: image, orientation: .up) }
        }
        let ocrMilliseconds = (CACurrentMediaTime() - started) * 1000
        if stillRequested {
            read(picture, lines: lines)
            return
        }
        let size = uprightSize(picture)
        let entries = MenuReader.entries(from: lines, aspect: size.height / max(size.width, 1), language: languages.language(of:))
        if !entries.isEmpty {
            let now = CACurrentMediaTime()
            lastTextSeen = now
            let frame = TextFrame(picture: picture, lines: lines, time: now, score: Self.readability(lines))
            // A newer frame wins unless a recent one read clearly better (this one is blurred).
            let keepsBest = bestTextFrame.map { now - $0.time < Self.stillWindow && $0.score > frame.score * 1.25 } ?? false
            if !keepsBest { bestTextFrame = frame }
        }
        onFrame?(FrameResult(entries: entries, imageSize: size, ocrMilliseconds: ocrMilliseconds))
    }

    private static func readability(_ lines: [OCRLine]) -> Double {
        lines.reduce(0) { $0 + Double($1.confidence) * Double($1.text.filter(\.isLetter).count) }
    }

    /// Frame queue only: freeze on `picture` and hand over what its own reading found, then read it
    /// in bands for the small print and hand that over too.
    private func read(_ picture: Picture, lines: [OCRLine]) {
        let still: CGImage
        switch picture {
        case .image(let image):
            still = image
        case .buffer(let buffer):
            let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
            guard let image = ciContext.createCGImage(upright, from: upright.extent) else {
                paused = false
                stillRequested = true // no picture from this one: the next frame is the still
                return
            }
            still = image
        }
        paused = true
        stillRequested = false
        bestTextFrame = nil
        onFreeze?(still)

        let aspect = CGFloat(still.height) / CGFloat(max(still.width, 1))
        let sampler = InkSampler(image: still)
        func result(_ lines: [OCRLine], isFinal: Bool) -> StillResult {
            let entries = MenuReader.entries(from: lines, aspect: aspect, language: languages.language(of:))
            let colors = entries.map { entry in sampler.map { $0.colors(for: entry.titleBox) } }
            return StillResult(image: still, entries: entries, colors: colors, isFinal: isFinal)
        }
        // Most of it is translated already, from aiming: the list can show up with the picture.
        let first = result(lines, isFinal: false)
        if !first.entries.isEmpty { onStill?(first) }
        let closer = reading { recognizer.lines(in: still, bands: 2) }
        onStill?(result(OCRTiles.merge([lines, closer]), isFinal: true))
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
        observeInterruptions()
    }

    /// The system can take the camera away (a call, another app, a phone too warm): say so, and
    /// restart after a failure, rather than sit on a frozen picture.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
                let value = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                guard let message = CameraController.message(for: value.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))) else { return }
                self?.onInterruption?(message)
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                self?.onInterruption?(nil)
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                }
            },
        ]
    }

    private static func message(for reason: AVCaptureSession.InterruptionReason?) -> String? {
        switch reason {
        case .videoDeviceNotAvailableInBackground?: return nil // nobody's looking
        case .videoDeviceNotAvailableDueToSystemPressure?: return "iPhone is too warm: the camera is resting"
        case .videoDeviceInUseByAnotherClient?: return "Another app is using the camera"
        default: return "Camera paused"
        }
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
