import XCTest

final class WatchCardInteractionTests: XCTestCase {
    // MARK: - Swipes

    func testASidewaysDragIsASwipeInItsDirection() {
        XCTAssertEqual(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 60, height: 5), predictedEndTranslation: CGSize(width: 60, height: 5)),
            .right
        )
        XCTAssertEqual(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: -60, height: -5), predictedEndTranslation: CGSize(width: -60, height: -5)),
            .left
        )
    }

    func testAQuickShortFlickCountsByItsPredictedTravel() {
        XCTAssertEqual(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 12, height: 2), predictedEndTranslation: CGSize(width: 90, height: 6)),
            .right
        )
    }

    func testAShortSlowDragIsNotASwipe() {
        XCTAssertNil(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 12, height: 2), predictedEndTranslation: CGSize(width: 14, height: 2))
        )
    }

    func testAMostlyVerticalDragIsNotASwipe() {
        // That's the collection paging, not a flip.
        XCTAssertNil(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 40, height: 80), predictedEndTranslation: CGSize(width: 60, height: 200))
        )
    }

    func testSwipesTurnTheCardOppositeWays() {
        XCTAssertEqual(WatchCardInteraction.flipHalfTurns(for: .right), 1)
        XCTAssertEqual(WatchCardInteraction.flipHalfTurns(for: .left), -1)
    }

    func testAnySwipeLeavesTheOtherSideShowing() {
        for direction in [WatchCardInteraction.SwipeDirection.left, .right] {
            let angle = Double(WatchCardInteraction.flipHalfTurns(for: direction)) * 180
            XCTAssertFalse(FlipGeometry.showsFront(atDegrees: angle))
        }
    }

    // MARK: - Turning

    func testTheCardTurnsTowardTheWearersHand() {
        // Clockwise (top to the right) on a left wrist, whose hand is to the screen's right.
        XCTAssertEqual(WatchCardInteraction.quarterTurnDegrees(wornOnRightWrist: false), 90)
        XCTAssertEqual(WatchCardInteraction.quarterTurnDegrees(wornOnRightWrist: true), -90)
    }

    // MARK: - visibleFaceSize

    func testALandscapeCardFitsTheWidthOfATallSpace() {
        let size = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 300, height: 200), flip: .book,
            showingFront: true, quarterTurned: false, fittedIn: CGSize(width: 200, height: 250)
        )
        XCTAssertEqual(size.width, 200, accuracy: 0.001)
        XCTAssertEqual(size.height, 133.333, accuracy: 0.001)
    }

    func testTurningALandscapeCardFitsItToTheTallSpacesHeight() {
        let size = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 300, height: 200), flip: .book,
            showingFront: true, quarterTurned: true, fittedIn: CGSize(width: 200, height: 250)
        )
        // On screen it's now portrait: 250 tall, and 2/3 of that wide.
        XCTAssertEqual(size.width, 166.667, accuracy: 0.001)
        XCTAssertEqual(size.height, 250, accuracy: 0.001)
    }

    func testAHandFlipsBackShowsWithTheFrontsDimensionsSwapped() {
        let front = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 300, height: 200), flip: .leftHand,
            showingFront: true, quarterTurned: false, fittedIn: CGSize(width: 200, height: 250)
        )
        let back = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 300, height: 200), flip: .leftHand,
            showingFront: false, quarterTurned: false, fittedIn: CGSize(width: 200, height: 250)
        )
        // Both fit a 200-point square (the hand flip's bounding box).
        XCTAssertEqual(front.width, 200, accuracy: 0.001)
        XCTAssertEqual(front.height, 133.333, accuracy: 0.001)
        XCTAssertEqual(back.width, front.height, accuracy: 0.001)
        XCTAssertEqual(back.height, front.width, accuracy: 0.001)
    }

    func testDegenerateSizesGiveZero() {
        XCTAssertEqual(
            WatchCardInteraction.visibleFaceSize(
                frontPixelSize: .zero, flip: .none, showingFront: true, quarterTurned: false, fittedIn: CGSize(width: 200, height: 250)
            ),
            .zero
        )
        XCTAssertEqual(
            WatchCardInteraction.visibleFaceSize(
                frontPixelSize: CGSize(width: 300, height: 200), flip: .none, showingFront: true, quarterTurned: false, fittedIn: .zero
            ),
            .zero
        )
    }
}
