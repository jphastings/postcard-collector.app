import CoreGraphics
import Foundation
import ImageIO
import Vision

/// On-device text recognition over a scanned image, used to prefill the "Create a Postcard"
/// transcription fields with a first guess at whatever's written on a side — the user reviews
/// and corrects it, this never writes directly into the model.
///
/// Built on `VNRecognizeTextRequest`/`VNImageRequestHandler` rather than the macOS-15-only
/// `RecognizeTextRequest` struct API, so this keeps compiling at the app's macOS 14 / iOS 17
/// floor.
enum HandwritingRecognizer {
    /// Recognizes text in `data` at Vision's most accurate level, with language correction on.
    /// Vision already segments the page into visually distinct lines; those are joined with
    /// newlines into one block. `nil` if the image can't be decoded, Vision errors, or finds
    /// no text at all.
    static func recognizeText(in data: Data) async -> String? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            recognizeText(in: cgImage)
        }.value
    }

    private static func recognizeText(in cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return nil
        }

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}
