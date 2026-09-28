import SwiftUI
import Translation

struct ContentView: View {
    @State private var model = AppModel()
    @State private var cameraZoomAtPinchStart: CGFloat?
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
                viewfinder.ignoresSafeArea()
                if model.mode == .reading {
                    // Edge to edge, but knowing where the Dynamic Island and the home bar are.
                    GeometryReader { safe in
                        let insets = safe.safeAreaInsets
                        ReadingScreen(
                            model: model,
                            size: CGSize(width: safe.size.width + insets.leading + insets.trailing,
                                         height: safe.size.height + insets.top + insets.bottom),
                            insets: insets
                        )
                        .ignoresSafeArea()
                    }
                    .transition(.opacity)
                } else {
                    controls.transition(.opacity)
                }
            }
        }
        .statusBarHidden()
        .animation(.easeOut(duration: 0.2), value: model.mode)
        .translationTask(model.engine.configuration) { session in
            await model.engine.run(session: session)
        }
        .task { await model.start() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.didEnterBackground() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.mode) { _, mode in mode == .reading }
    }

    /// The live camera, full screen (in demo mode, the demo picture).
    private var viewfinder: some View {
        Color.clear // takes the screen's size; the picture fills it without widening the layout
            .overlay {
                if let demo = model.demo {
                    Image(decorative: demo.image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    CameraPreview(session: model.camera.session)
                }
            }
            .clipped()
        .contentShape(Rectangle())
        .gesture(pinch)
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard model.mode == .aiming else { return }
                let start = cameraZoomAtPinchStart ?? model.zoom
                cameraZoomAtPinchStart = start
                model.setZoom(start * value.magnification)
            }
            .onEnded { _ in cameraZoomAtPinchStart = nil }
    }

    private var zoomLabel: String {
        let whole = model.zoom.rounded()
        return abs(model.zoom - whole) < 0.05 ? "\(Int(whole))×" : String(format: "%.1f×", Double(model.zoom))
    }

    private var hint: String? {
        guard model.cameraState == .running else { return nil }
        if model.isCapturing { return "Reading…" }
        return model.textInView ? "Hold still, or tap to translate" : "Point at a menu or a sign"
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                StatusPill(engine: model.engine, ocrMilliseconds: model.ocrMilliseconds)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            if let hint {
                Text(hint)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: hint)
            }

            HStack {
                RoundButton(
                    systemImage: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                    label: model.torchOn ? "Torch off" : "Torch on",
                    action: { model.toggleTorch() }
                )
                Spacer()
                ShutterButton(progress: model.captureProgress, isBusy: model.isCapturing) { model.capture() }
                Spacer()
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
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 16)
        }
        .foregroundStyle(.white)
    }
}

/// The shutter. Its ring fills while the phone is held still over text, and the picture is taken
/// when it's full; tap it to take the picture now.
private struct ShutterButton: View {
    let progress: Double
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.4), lineWidth: 4).frame(width: 78, height: 78)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentWarm, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 78, height: 78)
                    .animation(.linear(duration: 0.15), value: progress)
                Circle().fill(Color.white).frame(width: 64, height: 64).scaleEffect(isBusy ? 0.86 : 1)
                Image(systemName: "text.viewfinder")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.black)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isBusy)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Translate what's in view")
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
