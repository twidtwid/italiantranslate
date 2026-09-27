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
        let box = rect.insetBy(dx: -4, dy: -3) // cover the Italian completely
        let lineHeight = box.height / CGFloat(max(lineCount, 1))
        Text(text)
            .font(.system(size: min(max(lineHeight * 0.7, 12), 40), weight: .semibold))
            .foregroundStyle(.white)
            .minimumScaleFactor(0.35)
            .padding(.horizontal, 4)
            .frame(width: max(box.width, 40), height: max(box.height, 20), alignment: .leading)
            .background(Color.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .position(x: box.midX, y: box.midY)
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
