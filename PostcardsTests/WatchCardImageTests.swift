import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class WatchCardImageTests: XCTestCase {
    func testEncodedFaceIsSmallerAndPreservesAlpha() throws {
        let original = try XCTUnwrap(makeHalfTransparentImage(width: 400, height: 200))
        let naivePNG = try XCTUnwrap(encodedPNG(original))

        let output = try XCTUnwrap(WatchCardImage.encodedFace(original, maxPixelSize: 100))

        XCTAssertLessThan(output.count, naivePNG.count, "downsampling should shrink the payload")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 100)
        XCTAssertNotEqual(decoded.alphaInfo, .none, "the alpha channel must survive the round trip")
        XCTAssertTrue(alphaValues(of: decoded).contains { $0 < 200 }, "the transparent half must not be flattened to opaque")
    }

    func testNonPositiveMaxPixelSizeReturnsNil() throws {
        let original = try XCTUnwrap(makeHalfTransparentImage(width: 400, height: 200))
        XCTAssertNil(WatchCardImage.encodedFace(original, maxPixelSize: 0))
    }

    // MARK: - Fixtures

    /// A synthetic RGBA image, noisy-but-opaque on the left half (so PNG/HEIC compression
    /// can't trivially flatten the whole thing, which would make the "downsampling shrinks
    /// the payload" assertion meaningless) and fully transparent on the right — mirrors a
    /// die-cut postcard's soft alpha edge closely enough to prove transparency isn't lost,
    /// without needing a real fixture file.
    private func makeHalfTransparentImage(width: Int, height: Int) -> CGImage? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard x < width / 2 else { continue } // right half stays zeroed: transparent black
                let noise = UInt8((x * 7 + y * 13) % 256)
                buffer[offset] = noise
                buffer[offset + 1] = 255 &- noise
                buffer[offset + 2] = noise &* 3
                buffer[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func encodedPNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func alphaValues(of image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return [] }
        let buffer = UnsafeRawBufferPointer(start: data, count: width * height * 4)
        return stride(from: 3, to: buffer.count, by: 4).map { buffer[$0] }
    }
}
