import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Maps normalized image coordinates to a view showing that image aspect-filled and centered —
/// the same geometry as `AVLayerVideoGravity.resizeAspectFill` and SwiftUI's `scaledToFill()` —
/// optionally magnified and panned (pinch-zooming a locked still).
struct AspectFillMapper {
    var imageSize: CGSize
    var viewSize: CGSize
    /// Magnification on top of aspect-fill.
    var zoom: CGFloat = 1
    /// Offset in points; clamped so the image always covers the view.
    var pan: CGSize = .zero

    var displayedSize: CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height) * max(zoom, 1)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Where the whole image sits in view coordinates.
    var imageFrame: CGRect {
        let size = displayedSize
        let offset = clamped(pan)
        return CGRect(
            x: (viewSize.width - size.width) / 2 + offset.width,
            y: (viewSize.height - size.height) / 2 + offset.height,
            width: size.width,
            height: size.height
        )
    }

    func viewRect(for normalized: CGRect) -> CGRect {
        let frame = imageFrame
        return CGRect(
            x: frame.minX + normalized.minX * frame.width,
            y: frame.minY + normalized.minY * frame.height,
            width: normalized.width * frame.width,
            height: normalized.height * frame.height
        )
    }

    /// The part of the image that is actually on screen, in normalized image coordinates.
    var visibleRect: CGRect {
        let frame = imageFrame
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard frame.width > 0, frame.height > 0 else { return whole }
        return CGRect(
            x: -frame.minX / frame.width,
            y: -frame.minY / frame.height,
            width: viewSize.width / frame.width,
            height: viewSize.height / frame.height
        ).intersection(whole)
    }

    /// The pan that puts `normalized` in the middle of the view (clamp it before use).
    func centering(_ normalized: CGRect) -> CGSize {
        let size = displayedSize
        return CGSize(width: size.width * (0.5 - normalized.midX), height: size.height * (0.5 - normalized.midY))
    }

    /// The nearest pan that keeps the image covering the whole view.
    func clamped(_ pan: CGSize) -> CGSize {
        let size = displayedSize
        let maxX = max(0, (size.width - viewSize.width) / 2)
        let maxY = max(0, (size.height - viewSize.height) / 2)
        return CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }
}
