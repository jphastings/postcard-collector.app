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

    // MARK: - TapSequence

    func testASecondTapSoonAndNearIsADouble() {
        var taps = WatchCardInteraction.TapSequence()
        XCTAssertEqual(taps.classify(at: 10, location: CGPoint(x: 50, y: 50)), .single)
        XCTAssertEqual(taps.classify(at: 10.2, location: CGPoint(x: 70, y: 60)), .double)
    }

    func testASecondTapTooLateOrTooFarIsAnotherSingle() {
        var late = WatchCardInteraction.TapSequence()
        _ = late.classify(at: 10, location: .zero)
        XCTAssertEqual(late.classify(at: 10.5, location: .zero), .single)

        var far = WatchCardInteraction.TapSequence()
        _ = far.classify(at: 10, location: .zero)
        XCTAssertEqual(far.classify(at: 10.1, location: CGPoint(x: 60, y: 0)), .single)
    }

    func testATapAfterADoubleStartsAfresh() {
        var taps = WatchCardInteraction.TapSequence()
        _ = taps.classify(at: 10, location: .zero)
        _ = taps.classify(at: 10.2, location: .zero)
        XCTAssertEqual(taps.classify(at: 10.3, location: .zero), .single)
        XCTAssertEqual(taps.classify(at: 10.5, location: .zero), .double)
    }

    // MARK: - togglesFullScreen

    func testASwipeUpFromTheTopHidesTheControls() {
        XCTAssertTrue(WatchCardInteraction.togglesFullScreen(direction: .up, startY: 20, spaceHeight: 200, isFullScreen: false))
    }

    func testASwipeDownFromTheTopBringsThemBack() {
        XCTAssertTrue(WatchCardInteraction.togglesFullScreen(direction: .down, startY: 30, spaceHeight: 240, isFullScreen: true))
    }

    func testASwipeFromFurtherDownStillPages() {
        XCTAssertFalse(WatchCardInteraction.togglesFullScreen(direction: .up, startY: 120, spaceHeight: 200, isFullScreen: false))
        XCTAssertFalse(WatchCardInteraction.togglesFullScreen(direction: .down, startY: 150, spaceHeight: 240, isFullScreen: true))
    }

    func testASwipeFromTheTopPushingTheWayTheControlsAlreadyAreStillPages() {
        XCTAssertFalse(WatchCardInteraction.togglesFullScreen(direction: .down, startY: 10, spaceHeight: 200, isFullScreen: false))
        XCTAssertFalse(WatchCardInteraction.togglesFullScreen(direction: .up, startY: 10, spaceHeight: 240, isFullScreen: true))
    }

    func testTheTopEdgeIsTheTopQuarterOfTheSpace() {
        XCTAssertTrue(WatchCardInteraction.togglesFullScreen(direction: .up, startY: 50, spaceHeight: 200, isFullScreen: false))
        XCTAssertFalse(WatchCardInteraction.togglesFullScreen(direction: .up, startY: 50.5, spaceHeight: 200, isFullScreen: false))
    }

    func testSidewaysSwipesAndEmptySpacesNeverToggleFullScreen() {
        XCTAssertFalse(WatchCardInteraction.togglesFullScreen(direction: .left, startY: 10, spaceHeight: 200, isFullScreen: false))
        XCTAssertFalse(WatchCardInteraction.togglesFullScreen(direction: .right, startY: 10, spaceHeight: 200, isFullScreen: true))
        XCTAssertFalse(WatchCardInteraction.togglesFullScreen(direction: .up, startY: 0, spaceHeight: 0, isFullScreen: false))
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

    func testAPortraitHandFlipFittedToItsFrontUsesTheSpacesHeight() {
        let alone = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 200, height: 300), flip: .rightHand, fitsFrontOnly: true,
            showingFront: true, fittedIn: CGSize(width: 180, height: 240)
        )
        let bounded = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: CGSize(width: 200, height: 300), flip: .rightHand,
            showingFront: true, fittedIn: CGSize(width: 180, height: 240)
        )
        XCTAssertEqual(alone.width, 160, accuracy: 0.001)
        XCTAssertEqual(alone.height, 240, accuracy: 0.001)
        // Held to the space's width by the 300-point square its landscape back needs.
        XCTAssertEqual(bounded.width, 120, accuracy: 0.001)
        XCTAssertEqual(bounded.height, 180, accuracy: 0.001)
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

    // MARK: - cornerClearanceScale

    private let screen = CGSize(width: 208, height: 248)
    private var radius: CGFloat { screen.width * WatchCardInteraction.screenCornerRadiusFraction }

    /// The scale for a card resting full screen, in the 4pt-inset box `WatchCardView` uses.
    private func fullScreenScale(aspect: CGFloat) -> CGFloat {
        WatchCardInteraction.cornerClearanceScale(
            cardAspectRatio: aspect, restingBox: CGSize(width: 200, height: 248),
            space: CGRect(origin: .zero, size: screen), screen: screen, cornerRadius: radius
        )
    }

    func testASquareCardShrinksUntilItsCornersClearTheScreens() {
        let scale = fullScreenScale(aspect: 1)
        XCTAssertLessThan(scale, 1)
        // Fitted 200pt square, centred: its bottom-left corner against the bottom-left curve.
        let half = 100 * scale
        let corner = CGPoint(x: 104 - half, y: 124 + half)
        let distance = hypot(corner.x - radius, corner.y - (screen.height - radius))
        XCTAssertLessThanOrEqual(distance, radius - WatchCardInteraction.screenCornerMargin + 0.01)
        XCTAssertGreaterThan(distance, radius - WatchCardInteraction.screenCornerMargin - 0.5)
    }

    func testAWideLandscapeCardKeepsItsSize() {
        XCTAssertEqual(fullScreenScale(aspect: 3.0 / 2), 1)
    }

    func testATallCardWhoseCornersClearKeepsItsSize() {
        XCTAssertEqual(fullScreenScale(aspect: 0.35), 1)
    }
}
