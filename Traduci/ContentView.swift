import SwiftUI
import Translation

struct ContentView: View {
    @State private var model = AppModel()
    @State private var selectedItem: OverlayItem?
    @State private var zoomAtPinchStart: CGFloat?
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
        .sheet(item: $selectedItem) { item in
            TranslationDetail(item: item)
        }
    }

    private var viewfinder: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreview(session: model.camera.session)
                if let frozen = model.frozenImage {
                    Image(decorative: frozen, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                OverlayLayer(
                    items: model.items,
                    mapper: AspectFillMapper(imageSize: model.imageSize, viewSize: geometry.size),
                    onSelect: { selectedItem = $0 }
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: geometry.size, initial: true) { _, size in
                model.viewSize = size
            }
        }
        .ignoresSafeArea()
        .gesture(pinchToZoom)
    }

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !model.isFrozen else { return }
                let start = zoomAtPinchStart ?? model.zoom
                zoomAtPinchStart = start
                model.setZoom(start * value.magnification)
            }
            .onEnded { _ in zoomAtPinchStart = nil }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                StatusPill(engine: model.engine, ocrMilliseconds: model.ocrMilliseconds)
                Spacer(minLength: 12)
                if model.fastOCRAvailable {
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

            if model.isFrozen {
                Text("Frozen · tap a translation to read it in full")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 14)
            }

            HStack {
                RoundButton(
                    systemImage: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                    label: model.torchOn ? "Torch off" : "Torch on",
                    action: { model.toggleTorch() }
                )
                Spacer()
                FreezeButton(isFrozen: model.isFrozen || model.isFreezePending) { model.toggleFreeze() }
                Spacer()
                Button {
                    model.setZoom(1)
                } label: {
                    Text(model.zoom < 1.05 ? "1×" : String(format: "%.1f×", Double(model.zoom)))
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset zoom")
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

private struct FreezeButton: View {
    let isFrozen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 76, height: 76)
                Circle().fill(Color.white).frame(width: 62, height: 62)
                Image(systemName: isFrozen ? "play.fill" : "pause.fill")
                    .font(.title2)
                    .foregroundStyle(.black)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFrozen ? "Resume live translation" : "Freeze frame")
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
