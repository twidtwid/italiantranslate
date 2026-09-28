import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Point, then read. While aiming, the camera is live and clean and translation runs ahead in the
/// background. Holding still over text fills the shutter ring and takes the picture (or tap it).
/// The picture then stays, with the English laid over it and listed below, until the user goes back
/// to the camera: put the phone down, pass it across the table, it's still there.
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

    // Auto-capture. Any one signal fills the ring: the gyro says the phone is still, the camera sees
    // the same text in the same place frame after frame, or text has simply been in view a while.
    private static let steadyToCapture: TimeInterval = 0.5
    private static let stableFramesToCapture = 3
    private static let captureAnywayAfter: TimeInterval = 2.5
    private static let turnToRearm = 4.0 // degrees, after going back to the camera by hand
    private static let rearmAfter: TimeInterval = 3 // …or this long, whatever the gyro says
    static let maxStillZoom: CGFloat = 5

    let engine = TranslationEngine()
    let camera = CameraController()
    let demo = Demo.fromLaunchArguments()
    private let motion = MotionMonitor()

    private(set) var cameraState: CameraState = .starting
    private(set) var mode: Mode = .aiming
    /// Shutter pressed (or ring full), waiting for the still.
    private(set) var isCapturing = false
    /// The still is frozen on screen and being read closely.
    private(set) var isReadingPage = false
    /// How full the shutter ring is: auto-capture fires at 1.
    private(set) var captureProgress: Double = 0
    /// Italian text in view right now (aiming).
    private(set) var textInView = false
    /// Something to tell the user over the camera: it stopped, or a picture didn't come.
    private(set) var notice: String?
    private(set) var stillImage: CGImage?
    /// The captured page in reading order.
    private(set) var captions: [Caption] = []
    /// The entry the user picked, in the list or on the picture.
    private(set) var focusedID: Int?
    /// Where the pick came from: a pick in the list moves the picture, a pick on the picture moves the list.
    private(set) var focusFromList = false
    private(set) var stillZoom: CGFloat = 1
    var stillPan: CGSize = .zero
    private(set) var imageSize = CGSize(width: 1080, height: 1920)
    private(set) var ocrMilliseconds: Double?
    private(set) var torchOn = false
    private(set) var zoom: CGFloat = 1
    /// Lens stops the zoom button cycles through, relative to the main lens.
    private(set) var zoomStops: [CGFloat] = [1, 2]

    /// Size of the picture's area above the reading panel (set by the view).
    @ObservationIgnored var stillViewSize: CGSize = .zero
    /// Off after going back to the camera by hand, until the phone moves: no snapping straight back.
    @ObservationIgnored private var autoCaptureArmed = true
    @ObservationIgnored private var disarmedAt: TimeInterval = 0
    @ObservationIgnored private var previousEntries: [MenuEntry] = []
    @ObservationIgnored private var stableFrames = 0
    @ObservationIgnored private var textSince: TimeInterval?
    @ObservationIgnored private var steadyFor: TimeInterval = 0
    /// When the pending still was asked for: the watchdog's ticket.
    @ObservationIgnored private var captureStarted: TimeInterval = 0
    @ObservationIgnored private var shakingSince: TimeInterval?
    @ObservationIgnored private var calmSince: TimeInterval?
    @ObservationIgnored private var shortExposure = false
    /// The system has the camera (a call, another app, the phone too warm): no frames are coming.
    @ObservationIgnored private var interrupted = false

    init() {
        if let demo { engine.useCanned(demo.translations) }
        engine.onTranslation = { [weak self] source, translation in
            self?.didTranslate(source, to: translation)
        }
        camera.onFrame = { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async { // strictly in frame order
                MainActor.assumeIsolated { self.handleFrame(result) }
            }
        }
        camera.onFreeze = { [weak self] image in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.freeze(on: image) }
            }
        }
        camera.onStill = { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.handleStill(result) }
            }
        }
        camera.onInterruption = { [weak self] message in
            MainActor.assumeIsolated { self?.cameraInterrupted(message) } // delivered on the main queue
        }
        motion.onReading = { [weak self] reading in
            MainActor.assumeIsolated { self?.handleMotion(reading) } // delivered on the main queue
        }
    }

    func start() async {
        if let demo {
            cameraState = .running
            if demo.stage == .live { autoCaptureArmed = false }
            camera.startDemo(with: demo.image)
            return
        }
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

    // MARK: - Capturing

    /// The shutter: take the picture now.
    func capture() {
        guard mode == .aiming, !isCapturing, !interrupted else { return }
        isCapturing = true
        captureProgress = 1
        notice = nil
        let started = ProcessInfo.processInfo.systemUptime
        captureStarted = started
        camera.takeStill()
        Task { [weak self] in
            // A still comes within a frame or two. Overdue, get frames coming again; much later,
            // give up with a word rather than sit on "Reading…".
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isCapturing, self.captureStarted == started else { return }
            self.camera.recover()
            try? await Task.sleep(for: .seconds(3))
            guard self.isCapturing, self.captureStarted == started else { return }
            self.cancelCapture()
            self.show("The picture didn't come. Try again.")
        }
    }

    /// Stop waiting for a still: back to aiming, with the camera reading again, and no instant
    /// retry (the user taps again, or moves).
    private func cancelCapture() {
        isCapturing = false
        captureProgress = 0
        stableFrames = 0
        textSince = nil
        autoCaptureArmed = false
        disarmedAt = ProcessInfo.processInfo.systemUptime
        motion.mark()
        camera.resume()
    }

    /// A word over the camera for a few seconds.
    private func show(_ message: String) {
        notice = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.notice == message { self?.notice = nil }
        }
    }

    /// The system took the camera (a call, another app, a phone too warm), or gave it back (nil).
    private func cameraInterrupted(_ message: String?) {
        interrupted = message != nil
        notice = message
        guard interrupted else { return }
        textInView = false // what was in view is gone with the camera
        captureProgress = 0
        if isCapturing { cancelCapture() }
    }

    /// Back to the live camera. The only way out of reading: nothing else ends it.
    func backToCamera() {
        mode = .aiming
        isCapturing = false
        isReadingPage = false
        stillImage = nil
        captions = []
        focusedID = nil
        stillZoom = 1
        stillPan = .zero
        previousEntries = []
        stableFrames = 0
        textSince = nil
        captureProgress = 0
        autoCaptureArmed = false
        disarmedAt = ProcessInfo.processInfo.systemUptime
        motion.mark()
        camera.resume()
    }

    private func freeze(on image: CGImage) {
        // Only ever asked for while aiming; a late one, after the watchdog gave up, is still wanted.
        guard mode == .aiming else { return }
        isCapturing = false
        notice = nil
        stillImage = image
        imageSize = CGSize(width: image.width, height: image.height)
        captions = []
        focusedID = nil
        stillZoom = 1
        stillPan = .zero
        isReadingPage = true
        mode = .reading
    }

    private func handleStill(_ result: StillResult) {
        guard mode == .reading, isReadingPage else { return }
        isReadingPage = false
        captions = result.entries.enumerated().map { index, entry in
            var caption = Caption(id: index, entry: entry, colors: result.colors[index])
            for source in entry.sources {
                caption.english[source] = engine.cache[source]
            }
            return caption
        }
        engine.request(Captions.priority(result.entries, centralFirst: false))
        if let focus = demo?.focus, captions.indices.contains(focus) {
            self.focus(focus, fromList: true)
        }
    }

    private func handleFrame(_ result: FrameResult) {
        imageSize = result.imageSize
        ocrMilliseconds = result.ocrMilliseconds
        guard mode == .aiming else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !autoCaptureArmed, demo == nil, now - disarmedAt >= Self.rearmAfter { autoCaptureArmed = true }
        let entries = result.entries.filter { !$0.isForeign }
        textInView = !entries.isEmpty
        stableFrames = Captions.sameView(previousEntries, entries, aspect: result.imageSize.height / max(result.imageSize.width, 1))
            ? stableFrames + 1 : 0
        previousEntries = entries
        textSince = textInView ? (textSince ?? now) : nil
        engine.request(Captions.priority(entries, centralFirst: true)) // translate ahead: reading starts translated
        if demo?.stage == .reading, textInView {
            capture() // screenshots: no need to wait for a still picture to hold still
            return
        }
        updateCaptureProgress(now: now)
    }

    private func handleMotion(_ reading: MotionMonitor.Reading) {
        steadyFor = reading.steadyFor
        adjustExposure(shaking: reading.shaking)
        guard mode == .aiming else { return } // reading ignores motion entirely
        if !autoCaptureArmed, reading.degreesFromMark > Self.turnToRearm || reading.movedSharply {
            autoCaptureArmed = true
        }
        updateCaptureProgress(now: ProcessInfo.processInfo.systemUptime)
    }

    /// A phone that keeps shaking (a moving car, a walk) gets short exposures: grainier frames, but
    /// sharp ones. Back to normal once it has been calm for a moment.
    private func adjustExposure(shaking: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if shaking {
            calmSince = nil
            shakingSince = shakingSince ?? now
        } else {
            shakingSince = nil
            calmSince = calmSince ?? now
        }
        if !shortExposure, let since = shakingSince, now - since > 0.4 {
            shortExposure = true
            camera.setShortExposure(true)
        } else if shortExposure, let since = calmSince, now - since > 2 {
            shortExposure = false
            camera.setShortExposure(false)
        }
    }

    private func updateCaptureProgress(now: TimeInterval) {
        guard !isCapturing else { return }
        if demo?.stage == .live { // a still picture never steadies or wavers: show the ring mid-fill
            captureProgress = textInView ? 0.6 : 0
            return
        }
        guard autoCaptureArmed, textInView, !interrupted else {
            captureProgress = 0
            return
        }
        let gyro = steadyFor / Self.steadyToCapture
        let frames = Double(stableFrames) / Double(Self.stableFramesToCapture)
        let waited = (now - (textSince ?? now)) / Self.captureAnywayAfter
        captureProgress = min(1, max(gyro, frames, waited))
        if captureProgress >= 1 { capture() }
    }

    private func didTranslate(_ source: String, to translation: String) {
        for index in captions.indices where captions[index].entry.sources.contains(source) {
            captions[index].english[source] = translation
        }
    }

    // MARK: - Reading a picture

    func focus(_ id: Int?, fromList: Bool) {
        focusFromList = fromList
        focusedID = focusedID == id && !fromList ? nil : id
    }

    /// Pinch on the picture: zoom about the middle of the picture's area.
    func zoomStill(to zoom: CGFloat, from start: (zoom: CGFloat, pan: CGSize)) {
        let clamped = min(max(zoom, 1), Self.maxStillZoom)
        let ratio = clamped / max(start.zoom, 1)
        stillZoom = clamped
        stillPan = stillMapper.clamped(CGSize(width: start.pan.width * ratio, height: start.pan.height * ratio))
    }

    func panStill(to pan: CGSize) {
        stillPan = stillMapper.clamped(pan)
    }

    /// Bring an entry into view on the picture, closer if it's small.
    func showOnStill(_ id: Int) {
        guard let caption = captions.first(where: { $0.id == id }), stillViewSize.width > 0 else { return }
        var mapper = stillMapper
        let widthOnScreen = mapper.viewRect(for: caption.entry.box).width
        if widthOnScreen > 0 {
            let wanted = stillZoom * stillViewSize.width * 0.8 / widthOnScreen
            mapper.zoom = min(max(stillZoom, min(wanted, 2.5)), Self.maxStillZoom)
        }
        stillZoom = mapper.zoom
        stillPan = mapper.clamped(mapper.centering(caption.entry.box))
    }

    var stillMapper: AspectFillMapper {
        AspectFillMapper(imageSize: imageSize, viewSize: stillViewSize, zoom: stillZoom, pan: stillPan)
    }

    var shareText: String { Captions.plainText(captions) }

    // MARK: - Camera controls

    func toggleTorch() {
        torchOn.toggle()
        camera.setTorch(torchOn)
    }

    /// iOS switches the torch off in the background; keep the button honest.
    func didEnterBackground() {
        torchOn = false
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

/// Launch-argument demo mode, for Simulator screenshots in CI (the Simulator has no camera and no
/// translation models): a picture stands in for the camera and canned English for the translator.
///   -demo menu.jpg -demoTranslations english.json [-demoStage live|reading] [-demoPanel peek|half|full] [-demoFocus 3]
/// Files are looked up in the app's Documents folder.
struct Demo {
    enum Stage { case live, reading }

    let image: CGImage
    let translations: [String: String]
    let stage: Stage
    let panel: String?
    let focus: Int?

    static func fromLaunchArguments() -> Demo? {
        let defaults = UserDefaults.standard
        guard let name = defaults.string(forKey: "demo") else { return nil }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let source = CGImageSourceCreateWithURL(documents.appendingPathComponent(name) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var translations: [String: String] = [:]
        if let file = defaults.string(forKey: "demoTranslations"),
           let data = try? Data(contentsOf: documents.appendingPathComponent(file)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            translations = json
        }
        return Demo(
            image: image,
            translations: translations,
            stage: defaults.string(forKey: "demoStage") == "live" ? .live : .reading,
            panel: defaults.string(forKey: "demoPanel"),
            focus: defaults.object(forKey: "demoFocus") != nil ? defaults.integer(forKey: "demoFocus") : nil
        )
    }
}
