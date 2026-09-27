import SwiftUI

/// The English laid over a locked still. Each translation is painted in the page's own paper and
/// ink colors so it reads like print; lines still translating get a soft pulsing outline.
struct ReadingLayer: View {
    let captions: [Caption]
    let mapper: AspectFillMapper
    let onSelect: (Caption) -> Void

    var body: some View {
        ZStack {
            ForEach(captions) { caption in
                let rect = mapper.viewRect(for: caption.box)
                if caption.showsTranslation, let translation = caption.translation {
                    PrintedTranslation(text: translation, lineCount: caption.lineCount, rect: rect, colors: caption.colors)
                        .onTapGesture { onSelect(caption) }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else if caption.translation == nil {
                    PendingOutline(rect: rect)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.22), value: captions.map(\.translation))
    }
}

struct PrintedTranslation: View {
    let text: String
    let lineCount: Int
    let rect: CGRect
    let colors: InkSampler.Colors?

    var body: some View {
        let box = rect.insetBy(dx: -3, dy: -2)
        let lineHeight = box.height / CGFloat(max(lineCount, 1))
        let paper = colors.map { Color($0.paper) } ?? Color.black.opacity(0.8)
        let ink = colors.map { Color($0.ink) } ?? Color.white
        Text(text)
            .font(.system(size: max(lineHeight * 0.74, 6), weight: .medium))
            .foregroundStyle(ink)
            .minimumScaleFactor(0.4)
            .padding(.horizontal, 2)
            .frame(width: box.width, height: box.height, alignment: .leading)
            .background(paper, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .shadow(color: paper, radius: 2) // feather the edge into the page
            .position(x: box.midX, y: box.midY)
    }
}

/// "Translating this one": a soft outline that breathes until the English arrives.
struct PendingOutline: View {
    let rect: CGRect
    @State private var lit = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(Color.white.opacity(lit ? 0.9 : 0.25), lineWidth: 1.5)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .frame(width: rect.width + 8, height: rect.height + 6)
            .position(x: rect.midX, y: rect.midY)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { lit = true }
            }
    }
}

/// Full-size translation and original, for text too small to read in place.
struct TranslationDetail: View {
    let caption: Caption

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(caption.translation ?? "Translating…")
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Divider()
                Text(caption.source)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

extension Color {
    init(_ rgb: InkSampler.RGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
