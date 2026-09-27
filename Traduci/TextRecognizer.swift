import CoreVideo
import ImageIO
import Vision

/// On-device Italian OCR. Not thread-safe: use from the camera's frame queue only.
final class TextRecognizer {
    /// Whether Vision's fast recognizer reads Italian on this OS (it does on current releases).
    static let fastModeAvailable: Bool = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        let languages = (try? request.supportedRecognitionLanguages()) ?? []
        return languages.contains { $0.hasPrefix("it") }
    }()

    private let request: VNRecognizeTextRequest

    /// `minimumTextHeight` is a fraction of the image height. Vision's default, 1/32, misses menu
    /// text with a whole page in view; smaller catches tinier text but costs OCR time.
    init(minimumTextHeight: Float = 1.0 / 64.0) {
        request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["it-IT"]
        request.automaticallyDetectsLanguage = false
        request.minimumTextHeight = minimumTextHeight
    }

    func lines(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, fast: Bool) -> [OCRLine] {
        recognize(VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:]), fast: fast)
    }

    func lines(in image: CGImage, orientation: CGImagePropertyOrientation, fast: Bool) -> [OCRLine] {
        recognize(VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]), fast: fast)
    }

    private func recognize(_ handler: VNImageRequestHandler, fast: Bool) -> [OCRLine] {
        let useFast = fast && Self.fastModeAvailable
        request.recognitionLevel = useFast ? .fast : .accurate
        request.usesLanguageCorrection = !useFast
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
                corners: corners.map { CGPoint(x: $0.x, y: 1 - $0.y) }
            )
        }
    }
}
