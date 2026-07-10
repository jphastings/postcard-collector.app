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

    // MARK: - clampedOffset (watch double-tap zoom pan)

    func testClampedOffsetPassesThroughWithinBounds() {
        let containerSize = CGSize(width: 200, height: 300)
        let offset = CGSize(width: 10, height: 10)
        XCTAssertEqual(ZoomGeometry.clampedOffset(offset, scale: 2, containerSize: containerSize), offset)
    }

    func testClampedOffsetClampsToHalfTheScaledOverhang() {
        let containerSize = CGSize(width: 200, height: 300)
        // At scale 2, the content overhangs by (scale - 1) * size on each axis; half of
        // that is as far as it can pan before a gap would open at the opposite edge.
        let clamped = ZoomGeometry.clampedOffset(CGSize(width: 1000, height: -1000), scale: 2, containerSize: containerSize)
        XCTAssertEqual(clamped, CGSize(width: 100, height: -150))
    }

    func testClampedOffsetIsZeroWhenNotZoomedIn() {
        let clamped = ZoomGeometry.clampedOffset(CGSize(width: 50, height: 50), scale: 1, containerSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(clamped, .zero)
    }
}
