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

    func testAVerticalDragIsASwipeInItsDirection() {
        XCTAssertEqual(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 5, height: -70), predictedEndTranslation: CGSize(width: 5, height: -70)),
            .up
        )
        XCTAssertEqual(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: -4, height: 70), predictedEndTranslation: CGSize(width: -4, height: 70)),
            .down
        )
    }

    func testAQuickShortFlickCountsByItsPredictedTravel() {
        XCTAssertEqual(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 12, height: 2), predictedEndTranslation: CGSize(width: 90, height: 6)),
            .right
        )
        XCTAssertEqual(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 2, height: -12), predictedEndTranslation: CGSize(width: 5, height: -90)),
            .up
        )
    }

    func testAShortSlowDragIsNotASwipe() {
        XCTAssertNil(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 12, height: 2), predictedEndTranslation: CGSize(width: 14, height: 2))
        )
        XCTAssertNil(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 2, height: 12), predictedEndTranslation: CGSize(width: 2, height: 14))
        )
    }

    func testAMostlyVerticalDragPagesRatherThanFlips() {
        XCTAssertEqual(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 40, height: 80), predictedEndTranslation: CGSize(width: 60, height: 200)),
            .down
        )
    }

    func testADiagonalDragIsNeither() {
        // More sideways than vertical, but not clearly enough to flip the card.
        XCTAssertNil(
            WatchCardInteraction.swipeDirection(translation: CGSize(width: 60, height: 50), predictedEndTranslation: CGSize(width: 120, height: 100))
        )
    }

    func testSwipesTurnTheCardOppositeWays() {
        XCTAssertEqual(WatchCardInteraction.flipHalfTurns(for: .right), 1)
        XCTAssertEqual(WatchCardInteraction.flipHalfTurns(for: .left), -1)
    }

    func testAnySidewaysSwipeLeavesTheOtherSideShowing() {
        for direction in [WatchCardInteraction.SwipeDirection.left, .right] {
            let angle = Double(WatchCardInteraction.flipHalfTurns(for: direction) ?? 0) * 180
            XCTAssertFalse(FlipGeometry.showsFront(atDegrees: angle))
        }
    }

    func testVerticalSwipesPageAndNeverFlip() {
        XCTAssertEqual(WatchCardInteraction.pageStep(for: .up), 1)
        XCTAssertEqual(WatchCardInteraction.pageStep(for: .down), -1)
        XCTAssertNil(WatchCardInteraction.flipHalfTurns(for: .up))
        XCTAssertNil(WatchCardInteraction.flipHalfTurns(for: .down))
        XCTAssertNil(WatchCardInteraction.pageStep(for: .left))
        XCTAssertNil(WatchCardInteraction.pageStep(for: .right))
    }

    // MARK: - pageTarget

    func testPagingMovesToTheNeighbouringCard() {
        let cards = ["a", "b", "c"]
        XCTAssertEqual(WatchCardInteraction.pageTarget(from: "b", step: 1, in: cards), "c")
        XCTAssertEqual(WatchCardInteraction.pageTarget(from: "b", step: -1, in: cards), "a")
    }

    func testPagingStopsAtEitherEnd() {
        let cards = ["a", "b", "c"]
        XCTAssertNil(WatchCardInteraction.pageTarget(from: "c", step: 1, in: cards))
        XCTAssertNil(WatchCardInteraction.pageTarget(from: "a", step: -1, in: cards))
    }

    func testPagingFromAnUnknownCardGoesNowhere() {
        XCTAssertNil(WatchCardInteraction.pageTarget(from: "z", step: 1, in: ["a", "b"]))
    }

    // MARK: - pageDragOffset

    func testTheCardFollowsAVerticalDragPartWay() {
        XCTAssertEqual(WatchCardInteraction.pageDragOffset(forVerticalTranslation: -50, cardHeight: 240), -20, accuracy: 0.001)
        XCTAssertEqual(WatchCardInteraction.pageDragOffset(forVerticalTranslation: 50, cardHeight: 240), 20, accuracy: 0.001)
    }

    func testTheCardFollowsNoFurtherThanAQuarterOfItsHeight() {
        XCTAssertEqual(WatchCardInteraction.pageDragOffset(forVerticalTranslation: -400, cardHeight: 240), -60, accuracy: 0.001)
        XCTAssertEqual(WatchCardInteraction.pageDragOffset(forVerticalTranslation: 400, cardHeight: 240), 60, accuracy: 0.001)
    }

    // MARK: - visibleFaceSize

    func testALandscapeCardFitsTheWidthOfATallSpace() {
        let size = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 300, height: 200), flip: .book,
            showingFront: true, fittedIn: CGSize(width: 200, height: 250)
        )
        XCTAssertEqual(size.width, 200, accuracy: 0.001)
        XCTAssertEqual(size.height, 133.333, accuracy: 0.001)
    }

    func testAHandFlipsBackShowsWithTheFrontsDimensionsSwapped() {
        let front = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 300, height: 200), flip: .leftHand,
            showingFront: true, fittedIn: CGSize(width: 200, height: 250)
        )
        let back = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 300, height: 200), flip: .leftHand,
            showingFront: false, fittedIn: CGSize(width: 200, height: 250)
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
                frontPixelSize: .zero, flip: .none, showingFront: true, fittedIn: CGSize(width: 200, height: 250)
            ),
            .zero
        )
        XCTAssertEqual(
            WatchCardInteraction.visibleFaceSize(
                frontPixelSize: CGSize(width: 300, height: 200), flip: .none, showingFront: true, fittedIn: .zero
            ),
            .zero
        )
    }
}
