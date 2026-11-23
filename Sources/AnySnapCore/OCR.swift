#if os(macOS)
import CoreGraphics
import Vision

/// Text recognition on the window screenshot. Used when the Accessibility API is not
/// available (macOS 27.3+ no longer lets ordinary apps be granted Accessibility).
/// Needs no permission, but only sees text that is visible in the screenshot.
public enum OCR {
    public static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        guard let observations = request.results else { return "" }

        // Vision boxes are normalized with origin at the bottom-left.
        var items: [(box: CGRect, text: String)] = observations.compactMap { o in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            return (o.boundingBox, s)
        }
        items.sort { $0.box.midY > $1.box.midY }

        // Group boxes into visual lines, then order each line left to right.
        var lines: [[(box: CGRect, text: String)]] = []
        for item in items {
            if var last = lines.last, let ref = last.first,
               abs(ref.box.midY - item.box.midY) < min(ref.box.height, item.box.height) * 0.5 {
                last.append(item)
                lines[lines.count - 1] = last
            } else {
                lines.append([item])
            }
        }
        return lines
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ") }
            .joined(separator: "\n")
    }
}
#endif
