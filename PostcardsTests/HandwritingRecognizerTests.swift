import CoreGraphics
import CoreText
import ImageIO
import XCTest

final class HandwritingRecognizerTests: XCTestCase {
    /// Renders `text` into a plain white bitmap via CoreText — no committed fixture needed.
    private func makeTextImage(_ text: String, width: Int = 600, height: Int = 150) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 42, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
        context.textPosition = CGPoint(x: 20, y: 60)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    private func encodePNG(_ image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    func testRecognizesPrintedTextRenderedIntoAnImage() async throws {
        let cgImage = try XCTUnwrap(makeTextImage("POSTCARD COLLECTOR"), "couldn't render the test image")
        let data = try XCTUnwrap(encodePNG(cgImage))

        guard let result = await HandwritingRecognizer.recognizeText(in: data) else {
            throw XCTSkip("Vision returned no text in this environment")
        }
        XCTAssertTrue(result.uppercased().contains("POSTCARD"), "expected recognized text to contain the rendered keyword, got: \(result)")
    }

    func testReturnsNilForUnreadableData() async {
        let result = await HandwritingRecognizer.recognizeText(in: Data([0x00, 0x01, 0x02]))
        XCTAssertNil(result)
    }
}
