import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Maps normalized image coordinates to a view showing that image aspect-filled and centered —
/// the same geometry as `AVLayerVideoGravity.resizeAspectFill` and SwiftUI's `scaledToFill()`.
struct AspectFillMapper {
    var imageSize: CGSize
    var viewSize: CGSize

    private var displayedSize: CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private var origin: CGPoint {
        CGPoint(x: (viewSize.width - displayedSize.width) / 2, y: (viewSize.height - displayedSize.height) / 2)
    }

    func viewRect(for normalized: CGRect) -> CGRect {
        let size = displayedSize
        return CGRect(
            x: origin.x + normalized.minX * size.width,
            y: origin.y + normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    /// The part of the image that is actually on screen, in normalized image coordinates.
    var visibleRect: CGRect {
        let size = displayedSize
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard size.width > 0, size.height > 0 else { return whole }
        return CGRect(
            x: -origin.x / size.width,
            y: -origin.y / size.height,
            width: viewSize.width / size.width,
            height: viewSize.height / size.height
        ).intersection(whole)
    }
}
