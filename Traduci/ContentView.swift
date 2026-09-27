import SwiftUI
import Translation

struct ContentView: View {
    @State private var model = AppModel()
    @State private var selectedCaption: Caption?
    @State private var cameraZoomAtPinchStart: CGFloat?
    @State private var stillAtGestureStart: (zoom: CGFloat, pan: CGSize)?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.cameraState {
            case .denied:
                CameraMessage(
                    title: "Camera access is off",
                    detail: "Traduci needs the camera to read Italian. Nothing leaves this iPhone.",
                    showsSettingsButton: true
                )
            case .unavailable(let reason):
                CameraMessage(title: "Camera unavailable", detail: reason, showsSettingsButton: false)
            case .starting, .running:
                viewfinder
                controls
            }
        }
        .statusBarHidden()
        .translationTask(model.engine.configuration) { session in
            await model.engine.run(session: session)
        }
        .task { await model.start() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.didEnterBackground() }
        }
        .onChange(of: selectedCaption) { _, caption in
            model.isShowingDetail = caption != nil
        }
        .sensoryFeedback(.impact(weight: .light), trigger: model.mode) { _, mode in mode == .reading }
        .sheet(item: $selectedCaption) { caption in
            TranslationDetail(caption: caption)
        }
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            let mapper = AspectFillMapper(imageSize: model.imageSize, viewSize: geometry.size, zoom: model.stillZoom, pan: model.stillPan)
            ZStack {
                CameraPreview(session: model.camera.session)
                if let still = model.stillImage {
                    let frame = mapper.imageFrame
                    ZStack {
                        Image(decorative: still, scale: 1)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        ReadingLayer(captions: model.captions, mapper: mapper) { selectedCaption = $0 }
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.18), value: model.mode)
            .gesture(pinch)
            .simultaneousGesture(pan)
            .onChange(of: geometry.size, initial: true) { _, size in
                model.viewSize = size
            }
        }
        .ignoresSafeArea()
    }

    /// Aiming: camera zoom. Reading: magnify the still.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if model.mode == .reading {
                    let start = stillAtGestureStart ?? (zoom: model.stillZoom, pan: model.stillPan)
                    stillAtGestureStart = start
                    model.zoomStill(to: start.zoom * value.magnification, from: start)
                } else {
                    let start = cameraZoomAtPinchStart ?? model.zoom
                    cameraZoomAtPinchStart = start
                    model.setZoom(start * value.magnification)
                }
            }
            .onEnded { _ in
                cameraZoomAtPinchStart = nil
                stillAtGestureStart = nil
            }
    }

    /// Reading a magnified still: drag it around.
    private var pan: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard model.mode == .reading, model.stillZoom > 1 else { return }
                let start = stillAtGestureStart ?? (zoom: model.stillZoom, pan: model.stillPan)
                stillAtGestureStart = start
                model.panStill(to: CGSize(width: start.pan.width + value.translation.width,
                                          height: start.pan.height + value.translation.height))
            }
            .onEnded { _ in stillAtGestureStart = nil }
    }

    private var zoomLabel: String {
        let whole = model.zoom.rounded()
        return abs(model.zoom - whole) < 0.05 ? "\(Int(whole))×" : String(format: "%.1f×", Double(model.zoom))
    }

    private var hint: String? {
        guard model.mode == .aiming, model.cameraState == .running else { return nil }
        if model.isLocking { return "Reading…" }
        return model.textInView ? "Hold steady to translate" : "Point at Italian text"
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                StatusPill(engine: model.engine, ocrMilliseconds: model.ocrMilliseconds)
                Spacer(minLength: 12)
                if model.fastOCRAvailable, model.mode == .aiming {
                    Button {
                        model.toggleFastOCR()
                    } label: {
                        Label(model.fastOCR ? "Fast" : "Accurate", systemImage: model.fastOCR ? "hare.fill" : "tortoise.fill")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Switches text recognition between accurate and fast")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            if let hint {
                Label(hint, systemImage: "text.viewfinder")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: hint)
            }

            HStack {
                if model.mode == .aiming {
                    RoundButton(
                        systemImage: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                        label: model.torchOn ? "Torch off" : "Torch on",
                        action: { model.toggleTorch() }
                    )
                } else {
                    Color.clear.frame(width: 52, height: 52)
                }
                Spacer()
                LockButton(isReading: model.mode == .reading || model.isLocking) { model.toggleLock() }
                Spacer()
                if model.mode == .aiming {
                    Button {
                        model.cycleZoom()
                    } label: {
                        Text(zoomLabel)
                            .font(.footnote.weight(.bold).monospacedDigit())
                            .frame(width: 52, height: 52)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zoom \(zoomLabel)")
                    .accessibilityHint("Switches to the next lens")
                } else {
                    Color.clear.frame(width: 52, height: 52)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
        .foregroundStyle(.white)
    }
}

private struct StatusPill: View {
    let engine: TranslationEngine
    let ocrMilliseconds: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(title).font(.footnote.weight(.semibold))
            }
            if let timing {
                Text(timing)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if engine.canRetry { engine.retry() }
        }
    }

    private var title: String {
        switch engine.status {
        case .preparing: return "Loading translator…"
        case .needsDownload: return "Tap to download Italian (once)"
        case .ready(let offline): return offline ? "IT → EN · offline" : "IT → EN"
        case .unsupported: return "Italian → English unavailable"
        case .failed(let message): return message
        }
    }

    private var dotColor: Color {
        switch engine.status {
        case .ready(let offline): return offline ? .green : .yellow
        case .preparing: return .yellow
        case .needsDownload: return .orange
        case .unsupported, .failed: return .red
        }
    }

    private var timing: String? {
        var parts: [String] = []
        if let ocrMilliseconds { parts.append("OCR \(Int(ocrMilliseconds.rounded())) ms") }
        if let translation = engine.latencyMilliseconds { parts.append("MT \(Int(translation.rounded())) ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct RoundButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Read what's in view now, or go back to aiming. Holding still does the same by itself.
private struct LockButton: View {
    let isReading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(Color.white).frame(width: 62, height: 62)
                Image(systemName: isReading ? "camera.fill" : "text.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isReading ? "Back to the camera" : "Translate what's in view")
    }
}

private struct CameraMessage: View {
    let title: String
    let detail: String
    let showsSettingsButton: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 40))
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .multilineTextAlignment(.center)
                .opacity(0.75)
            if showsSettingsButton {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }
}
