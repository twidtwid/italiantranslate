import CoreVideo
import ImageIO
import os
import Vision

/// On-device Italian OCR. Not thread-safe: use from the camera's frame queue only, except `cancel()`.
final class TextRecognizer {
    private let minimumTextHeight: Float
    /// The read in progress, so the watchdog can cancel it from another queue.
    private let current = OSAllocatedUnfairLock<VNRecognizeTextRequest?>(uncheckedState: nil)

    /// `minimumTextHeight` is a fraction of the image height. Vision's default, 1/32, misses menu
    /// text with a whole page in view; smaller catches tinier text but costs OCR time.
    init(minimumTextHeight: Float = 1.0 / 64.0) {
        self.minimumTextHeight = minimumTextHeight
    }

    func lines(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [OCRLine] {
        recognize(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]))
    }

    func lines(in image: CGImage, orientation: CGImagePropertyOrientation) -> [OCRLine] {
        recognize(VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]))
    }

    /// Reads only `region` (normalized, origin top-left) of an upright image. Vision reads at a fixed
    /// working resolution, so a smaller region is a closer look: the small print of a whole-page
    /// shot (prices, allergens) comes out. Lines come back in whole-image coordinates, without
    /// the ones the region's inner edges cut through.
    func lines(in image: CGImage, region: CGRect) -> [OCRLine] {
        let lines = recognize(VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]),
                              region: CGRect(x: region.minX, y: 1 - region.maxY, width: region.width, height: region.height))
            .map { $0.mapped(from: region) }
        return OCRTiles.droppingCut(lines, in: region)
    }

    /// The whole image in overlapping bands, each line once.
    func lines(in image: CGImage, bands: Int) -> [OCRLine] {
        OCRTiles.merge(OCRTiles.bands(bands).map { lines(in: image, region: $0) })
    }

    /// Stops the read in progress (it comes back empty). Safe from any queue: the watchdog's way
    /// out of a read that has run for seconds.
    func cancel() {
        current.withLockUnchecked { $0?.cancel() }
    }

    /// `region` in Vision's coordinates (origin bottom-left).
    private func recognize(_ handler: VNImageRequestHandler, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [OCRLine] {
        let request = VNRecognizeTextRequest() // one per read: a cancelled request stays cancelled
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT"]
        request.automaticallyDetectsLanguage = false
        request.minimumTextHeight = minimumTextHeight
        request.regionOfInterest = region
        current.withLockUnchecked { $0 = request }
        defer { current.withLockUnchecked { $0 = nil } }
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { return nil }
            let box = observation.boundingBox // normalized, origin bottom-left
            let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            return OCRLine(
                text: best.string,
                box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                corners: corners.map { CGPoint(x: $0.x, y: 1 - $0.y) },
                confidence: best.confidence
            )
        }
    }
}
