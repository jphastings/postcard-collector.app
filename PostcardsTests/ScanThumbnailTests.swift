import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class ScanThumbnailTests: XCTestCase {
    private func makePNGData(width: Int, height: Int) -> Data {
        let image = makeTestImage(width: width, height: height) { _, _ in (200, 120, 40) }
        let mutableData = NSMutableData()
        let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return mutableData as Data
    }

    func testDecodeBoundsBothDimensionsToMaxPixelSize() throws {
        let data = makePNGData(width: 800, height: 400)
        let thumbnail = try XCTUnwrap(ScanThumbnail.decode(from: data, maxPixelSize: 200))
        XCTAssertLessThanOrEqual(thumbnail.width, 200)
        XCTAssertLessThanOrEqual(thumbnail.height, 200)
    }

    func testDecodePreservesAspectRatio() throws {
        let data = makePNGData(width: 800, height: 400)
        let thumbnail = try XCTUnwrap(ScanThumbnail.decode(from: data, maxPixelSize: 200))
        XCTAssertEqual(Double(thumbnail.width) / Double(thumbnail.height), 2.0, accuracy: 0.05)
    }

    func testDecodeReturnsNilForUnreadableData() {
        XCTAssertNil(ScanThumbnail.decode(from: Data([0x00, 0x01]), maxPixelSize: 200))
    }
}
