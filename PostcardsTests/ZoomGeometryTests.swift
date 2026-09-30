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

    // MARK: - clampedOffset (watch double-tap zoom pan)

    func testClampedOffsetPassesThroughWithinBounds() {
        let containerSize = CGSize(width: 200, height: 300)
        let offset = CGSize(width: 10, height: 10)
        XCTAssertEqual(ZoomGeometry.clampedOffset(offset, contentSize: CGSize(width: 400, height: 600), containerSize: containerSize), offset)
    }

    func testClampedOffsetClampsToHalfTheOverhang() {
        let containerSize = CGSize(width: 200, height: 300)
        // Content twice the container's size overhangs by one container on each axis; half of
        // that is as far as it can pan before a gap would open at the opposite edge.
        let clamped = ZoomGeometry.clampedOffset(
            CGSize(width: 1000, height: -1000), contentSize: CGSize(width: 400, height: 600), containerSize: containerSize
        )
        XCTAssertEqual(clamped, CGSize(width: 100, height: -150))
    }

    func testClampedOffsetIsZeroWhenTheContentFits() {
        let clamped = ZoomGeometry.clampedOffset(
            CGSize(width: 50, height: 50), contentSize: CGSize(width: 200, height: 200), containerSize: CGSize(width: 200, height: 200)
        )
        XCTAssertEqual(clamped, .zero)
    }

    func testClampedOffsetKeepsContentCentredAlongAnAxisItDoesNotOverflow() {
        // A zoomed landscape card: wider than the screen, but still shorter than it.
        let clamped = ZoomGeometry.clampedOffset(
            CGSize(width: -80, height: 60), contentSize: CGSize(width: 500, height: 250), containerSize: CGSize(width: 200, height: 300)
        )
        XCTAssertEqual(clamped, CGSize(width: -80, height: 0))
    }
}
