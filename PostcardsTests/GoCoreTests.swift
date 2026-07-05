import XCTest
import CoreGraphics
import ImageIO

/// Direct, end-to-end tests against the Go core (no @testable import — see README), using
/// the bundled fixture collection copied into the test bundle as a resource.
final class GoCoreTests: XCTestCase {
    private func fixturePath() throws -> String {
        try XCTUnwrap(
            Bundle(for: GoCoreTests.self).url(forResource: "fixture", withExtension: "postcards"),
            "fixture.postcards must be a test bundle resource"
        ).path
    }

    func testBundledFixtureTitleReadsSampleCollectionThroughGoCore() async throws {
        let title = try await GoCore.shared.title(ofCollectionAt: try fixturePath())
        XCTAssertEqual(title, "Sample Collection")
    }

    /// Regression test for the grid's "no plate behind transparent cards" requirement: a
    /// transparent card's thumbnail must actually be a PNG carrying real alpha, not a JPEG
    /// with the transparency flattened to a solid colour.
    func testTransparentCardThumbnailIsPNGWithTransparentCorners() async throws {
        let data = try await GoCore.shared.thumbnail(forCard: "transparency-card", inCollectionAt: try fixturePath())

        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(data.prefix(8)), pngSignature, "must stay PNG, not fall back to JPEG, to preserve alpha")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(topLeftAlpha(of: image), 0, "corner pixel should be fully transparent, not matted to black/white")
    }

    private func topLeftAlpha(of image: CGImage) -> UInt8 {
        let width = image.width
        let height = image.height
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = context.data!.assumingMemoryBound(to: UInt8.self)
        return buffer[3]
    }
}
