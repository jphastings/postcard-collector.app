import XCTest

final class ZoomGeometryTests: XCTestCase {
    private func screenPos(of point: CGPoint, contentSize: CGSize, scale: CGFloat, offset: CGSize) -> CGPoint {
        let center = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        return CGPoint(
            x: center.x + offset.width + scale * (point.x - center.x),
            y: center.y + offset.height + scale * (point.y - center.y)
        )
    }

    func testAnchorPointStaysFixedOnScreenWhenZoomingIn() {
        let contentSize = CGSize(width: 400, height: 300)
        let anchor = CGPoint(x: 120, y: 80) // off-center, not at the origin either
        let before = screenPos(of: anchor, contentSize: contentSize, scale: 1, offset: .zero)

        let newOffset = ZoomGeometry.offset(
            keepingAnchor: anchor, inContentOfSize: contentSize,
            previousScale: 1, previousOffset: .zero, newScale: 2.5
        )
        let after = screenPos(of: anchor, contentSize: contentSize, scale: 2.5, offset: newOffset)

        XCTAssertEqual(before.x, after.x, accuracy: 0.001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.001)
    }

    func testAnchorPointStaysFixedWhenContinuingToZoomFromAnExistingPanAndScale() {
        // Simulates a second pinch on top of an already-zoomed, already-panned state —
        // the case that specifically broke before (anchor drifted on repeated zooming).
        let contentSize = CGSize(width: 500, height: 350)
        let anchor = CGPoint(x: 50, y: 300)
        let existingScale: CGFloat = 1.8
        let existingOffset = CGSize(width: -40, height: 65)
        let before = screenPos(of: anchor, contentSize: contentSize, scale: existingScale, offset: existingOffset)

        let newOffset = ZoomGeometry.offset(
            keepingAnchor: anchor, inContentOfSize: contentSize,
            previousScale: existingScale, previousOffset: existingOffset, newScale: 3.2
        )
        let after = screenPos(of: anchor, contentSize: contentSize, scale: 3.2, offset: newOffset)

        XCTAssertEqual(before.x, after.x, accuracy: 0.001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.001)
    }

    func testCenterAnchorNeedsNoOffsetChange() {
        let contentSize = CGSize(width: 400, height: 300)
        let center = CGPoint(x: 200, y: 150)
        let newOffset = ZoomGeometry.offset(
            keepingAnchor: center, inContentOfSize: contentSize,
            previousScale: 1, previousOffset: .zero, newScale: 3
        )
        XCTAssertEqual(newOffset, .zero)
    }

    func testZoomingOutBackToOriginalScaleRestoresOriginalOffset() {
        let contentSize = CGSize(width: 400, height: 300)
        let anchor = CGPoint(x: 90, y: 40)
        let zoomedOffset = ZoomGeometry.offset(
            keepingAnchor: anchor, inContentOfSize: contentSize,
            previousScale: 1, previousOffset: .zero, newScale: 2
        )
        let backToOriginal = ZoomGeometry.offset(
            keepingAnchor: anchor, inContentOfSize: contentSize,
            previousScale: 2, previousOffset: zoomedOffset, newScale: 1
        )
        XCTAssertEqual(backToOriginal.width, 0, accuracy: 0.001)
        XCTAssertEqual(backToOriginal.height, 0, accuracy: 0.001)
    }

    // MARK: - contentPoint

    func testContentPointInvertsTheScreenMapping() {
        let contentSize = CGSize(width: 390, height: 844)
        let point = CGPoint(x: 70, y: 610)
        let scale: CGFloat = 2.7
        let offset = CGSize(width: -35, height: 120)
        let onScreen = screenPos(of: point, contentSize: contentSize, scale: scale, offset: offset)

        let recovered = ZoomGeometry.contentPoint(atScreenPoint: onScreen, inContentOfSize: contentSize, scale: scale, offset: offset)

        XCTAssertEqual(recovered.x, point.x, accuracy: 0.001)
        XCTAssertEqual(recovered.y, point.y, accuracy: 0.001)
    }

    func testAtRestTheScreenAndContentPointsCoincide() {
        let contentSize = CGSize(width: 390, height: 844)
        let screenPoint = CGPoint(x: 120, y: 300)
        XCTAssertEqual(
            ZoomGeometry.contentPoint(atScreenPoint: screenPoint, inContentOfSize: contentSize, scale: 1, offset: .zero),
            screenPoint
        )
    }

    func testAPinchOnAZoomedCardKeepsWhatsUnderTheFingersThere() {
        // The pinch reports where the fingers are on screen; the card point there has to come
        // from the zoom and pan it started from, or a second pinch drifts.
        let contentSize = CGSize(width: 390, height: 844)
        let fingers = CGPoint(x: 300, y: 200)
        let startScale: CGFloat = 2
        let startOffset = CGSize(width: 60, height: -90)

        let anchor = ZoomGeometry.contentPoint(atScreenPoint: fingers, inContentOfSize: contentSize, scale: startScale, offset: startOffset)
        let newOffset = ZoomGeometry.offset(
            keepingAnchor: anchor, inContentOfSize: contentSize,
            previousScale: startScale, previousOffset: startOffset, newScale: 3.5
        )
        let after = screenPos(of: anchor, contentSize: contentSize, scale: 3.5, offset: newOffset)

        XCTAssertEqual(after.x, fingers.x, accuracy: 0.001)
        XCTAssertEqual(after.y, fingers.y, accuracy: 0.001)
    }

    // MARK: - resistedScale

    func testAScaleWithinRangeIsShownAsIs() {
        XCTAssertEqual(ZoomGeometry.resistedScale(2.4, within: 1...5), 2.4)
        XCTAssertEqual(ZoomGeometry.resistedScale(1, within: 1...5), 1)
        XCTAssertEqual(ZoomGeometry.resistedScale(5, within: 1...5), 5)
    }

    func testPinchingPastEitherEndGivesOnlyAFraction() {
        XCTAssertEqual(ZoomGeometry.resistedScale(0.5, within: 1...5), 0.85, accuracy: 0.0001)
        XCTAssertEqual(ZoomGeometry.resistedScale(7, within: 1...5), 5.6, accuracy: 0.0001)
    }

    func testTheResistedScaleKeepsFollowingThePinch() {
        // Continuous across the ends — no jump as the pinch crosses 1× — and still moving the
        // same way as the fingers beyond them.
        XCTAssertEqual(ZoomGeometry.resistedScale(0.9999, within: 1...5), 1, accuracy: 0.001)
        XCTAssertLessThan(ZoomGeometry.resistedScale(0.6, within: 1...5), ZoomGeometry.resistedScale(0.8, within: 1...5))
        XCTAssertGreaterThan(ZoomGeometry.resistedScale(6, within: 1...5), ZoomGeometry.resistedScale(5.5, within: 1...5))
    }

    func testTheResistedScaleNeverGoesNegative() {
        XCTAssertEqual(ZoomGeometry.resistedScale(-100, within: 1...5), 0)
    }

    // MARK: - Pan bounds & rubber banding

    private let viewport = CGSize(width: 1000, height: 800)
    private let card = CGRect(x: 100, y: 100, width: 800, height: 600)

    /// How much of the card's width is on screen, for content scaled about the viewport centre.
    private func visibleWidth(offset: CGFloat, scale: CGFloat) -> CGFloat {
        let center = viewport.width / 2
        let left = center + offset + scale * (card.minX - center)
        let right = center + offset + scale * (card.maxX - center)
        return min(right, viewport.width) - max(left, 0)
    }

    func testPanBoundsLeaveAQuarterOfTheZoomedCardOnScreen() {
        let bounds = ZoomGeometry.panBounds(card: card, viewport: viewport, scale: 2)
        let quarter = 0.25 * card.width * 2

        XCTAssertEqual(visibleWidth(offset: bounds.x.upperBound, scale: 2), quarter, accuracy: 0.001)
        XCTAssertEqual(visibleWidth(offset: bounds.x.lowerBound, scale: 2), quarter, accuracy: 0.001)
        XCTAssertTrue(bounds.contains(.zero))
    }

    func testClampSettlesAnOffscreenCardBackToTheBound() {
        let bounds = ZoomGeometry.panBounds(card: card, viewport: viewport, scale: 2)
        let settled = bounds.clamp(CGSize(width: 5000, height: -5000))
        XCTAssertEqual(settled, CGSize(width: bounds.x.upperBound, height: bounds.y.lowerBound))
    }

    func testRubberBandingGivesLessAndLessPastTheBound() {
        let bounds = ZoomGeometry.panBounds(card: card, viewport: viewport, scale: 2)
        let edge = bounds.x.upperBound
        func shown(_ pull: CGFloat) -> CGFloat {
            bounds.rubberBanded(CGSize(width: edge + pull, height: 0), viewport: viewport).width - edge
        }

        XCTAssertEqual(bounds.rubberBanded(CGSize(width: 10, height: -10), viewport: viewport), CGSize(width: 10, height: -10))
        XCTAssertLessThan(shown(100), 100)
        XCTAssertGreaterThan(shown(200), shown(100))
        XCTAssertLessThan(shown(200) - shown(100), shown(100), "each further pull should move the card less")
        XCTAssertLessThan(shown(1_000_000), viewport.width)
    }
}
