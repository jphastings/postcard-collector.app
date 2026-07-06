import XCTest

final class MiniCardSizingTests: XCTestCase {
    func testHomorientedCardScalesToTargetLongestSide() {
        // 300x200, homoriented: bounding box is the front itself, so the frame's longer
        // side (300 -> width) should land exactly on the target.
        let size = MiniCardSizing.frameSize(forFrontSize: CGSize(width: 300, height: 200), flip: .book, targetLongestSide: 180)

        XCTAssertEqual(size.width, 180, accuracy: 0.001)
        XCTAssertEqual(size.height, 120, accuracy: 0.001)
    }

    func testPortraitHomorientedCardScalesHeightToTarget() {
        let size = MiniCardSizing.frameSize(forFrontSize: CGSize(width: 200, height: 300), flip: .calendar, targetLongestSide: 180)

        XCTAssertEqual(size.height, 180, accuracy: 0.001)
        XCTAssertEqual(size.width, 120, accuracy: 0.001)
    }

    func testHandFlipCardIsSquareAtTargetSide() {
        // Hand flips bound to a square (see FlipGeometry.boundingSize) — both dimensions
        // should land on the target.
        let size = MiniCardSizing.frameSize(forFrontSize: CGSize(width: 300, height: 200), flip: .leftHand, targetLongestSide: 180)

        XCTAssertEqual(size.width, 180, accuracy: 0.001)
        XCTAssertEqual(size.height, 180, accuracy: 0.001)
    }

    func testDegenerateFrontSizeFallsBackToATargetSquareRatherThanZero() {
        let size = MiniCardSizing.frameSize(forFrontSize: .zero, flip: .book, targetLongestSide: 180)
        XCTAssertEqual(size.width, 180)
        XCTAssertEqual(size.height, 180)
    }

    func testDefaultTargetMatchesTheDocumentedCompactSize() {
        let size = MiniCardSizing.frameSize(forFrontSize: CGSize(width: 300, height: 200), flip: .book)
        XCTAssertEqual(max(size.width, size.height), MiniCardSizing.defaultTargetLongestSide, accuracy: 0.001)
    }
}
