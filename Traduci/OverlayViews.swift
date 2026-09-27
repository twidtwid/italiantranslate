import SwiftUI

/// English drawn over the Italian it replaces.
struct OverlayLayer: View {
    let items: [OverlayItem]
    let mapper: AspectFillMapper
    let onSelect: (OverlayItem) -> Void

    var body: some View {
        ZStack {
            ForEach(items) { item in
                if let translation = item.translation,
                   !TextNormalizer.isEffectivelySame(item.source, translation) {
                    TranslationBubble(text: translation, lineCount: item.lineCount, rect: mapper.viewRect(for: item.box))
                        .onTapGesture { onSelect(item) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TranslationBubble: View {
    let text: String
    let lineCount: Int
    let rect: CGRect

    var body: some View {
        // Exactly over the Italian it replaces. Inflating small boxes is what piled up dense text.
        let box = rect.insetBy(dx: -3, dy: -1)
        let lineHeight = box.height / CGFloat(max(lineCount, 1))
        Text(text)
            .font(.system(size: max(lineHeight * 0.75, 6), weight: .semibold))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.4)
            .padding(.horizontal, 2)
            .frame(width: box.width, height: box.height, alignment: .leading)
            .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .position(x: box.midX, y: box.midY)
            .animation(.easeOut(duration: 0.15), value: rect) // glide, don't jump, when the text really moves
    }
}

/// Full-size translation and original, for text too small to read in place.
struct TranslationDetail: View {
    let item: OverlayItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.translation ?? "…")
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Divider()
                Text(item.source)
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
