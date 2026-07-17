import CoreGraphics
import XCTest

final class SecretRegionTests: XCTestCase {
    // MARK: - Clamping

    func testClampingConfinesRectToUnitSquare() {
        let clamped = SecretRegion.clamped(CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5))
        XCTAssertEqual(clamped.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(clamped.maxY, 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(clamped.minX, 0)
        XCTAssertGreaterThanOrEqual(clamped.minY, 0)
    }

    func testClampingStandardizesANegativeSizeRect() {
        // A right-to-left, bottom-to-top drag produces a negative-size rect.
        let clamped = SecretRegion.clamped(CGRect(x: 0.6, y: 0.6, width: -0.3, height: -0.3))
        XCTAssertEqual(clamped, CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3))
    }

    func testClampingEnforcesMinimumDimension() {
        let clamped = SecretRegion.clamped(CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
        XCTAssertEqual(clamped.width, SecretRegion.minimumDimension)
        XCTAssertEqual(clamped.height, SecretRegion.minimumDimension)
    }

    func testConstructorClampsOnInit() {
        let region = SecretRegion(rect: CGRect(x: -0.5, y: -0.5, width: 0.2, height: 0.2))
        XCTAssertEqual(region.rect.minX, 0)
        XCTAssertEqual(region.rect.minY, 0)
    }

    // MARK: - Applying a drag delta

    func testApplyingDeltaToTopLeftHandleMovesOnlyItsOwnedEdges() {
        let rect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let resized = SecretRegion.applying(delta: CGVector(dx: 0.1, dy: 0.1), to: .topLeft, of: rect)

        XCTAssertEqual(resized.minX, 0.4, accuracy: 0.0001)
        XCTAssertEqual(resized.minY, 0.4, accuracy: 0.0001)
        XCTAssertEqual(resized.maxX, rect.maxX, accuracy: 0.0001, "bottomRight-owned edges must stay put")
        XCTAssertEqual(resized.maxY, rect.maxY, accuracy: 0.0001)
    }

    func testApplyingDeltaToRightHandleOnlyMovesMaxX() {
        let rect = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
        let resized = SecretRegion.applying(delta: CGVector(dx: 0.1, dy: 0.4), to: .right, of: rect)

        XCTAssertEqual(resized.maxX, 0.6, accuracy: 0.0001)
        XCTAssertEqual(resized.minY, rect.minY, accuracy: 0.0001, "a side handle must not move the perpendicular edges")
        XCTAssertEqual(resized.maxY, rect.maxY, accuracy: 0.0001)
    }

    func testApplyingDeltaNeverExceedsTheUnitSquare() {
        let rect = CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
        let resized = SecretRegion.applying(delta: CGVector(dx: 0.5, dy: 0.5), to: .bottomRight, of: rect)

        XCTAssertLessThanOrEqual(resized.maxX, 1.0001)
        XCTAssertLessThanOrEqual(resized.maxY, 1.0001)
    }

    func testApplyingDeltaJustPastTheOppositeEdgeCollapsesToMinimumSizeInsteadOfInverting() {
        let rect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        // Dragging the right edge to just past the left edge produces a near-zero-width
        // standardized rect, which the minimum-size floor then grows back out.
        let resized = SecretRegion.applying(delta: CGVector(dx: -0.201, dy: 0), to: .right, of: rect)

        XCTAssertEqual(resized.width, SecretRegion.minimumDimension, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(resized.minX, 0)
    }

    // MARK: - Normalized <-> view space

    func testNormalizedAndViewSpaceRoundTrip() {
        let normalized = CGRect(x: 0.25, y: 0.5, width: 0.3, height: 0.1)
        let displaySize = CGSize(width: 800, height: 400)

        let view = SecretRegion.viewRect(ofNormalized: normalized, displaySize: displaySize)
        XCTAssertEqual(view, CGRect(x: 200, y: 200, width: 240, height: 40))

        let roundTripped = SecretRegion.normalizedRect(ofView: view, displaySize: displaySize)
        XCTAssertEqual(roundTripped.minX, normalized.minX, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.minY, normalized.minY, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.width, normalized.width, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.height, normalized.height, accuracy: 0.0001)
    }

    func testNormalizedPointMatchesTheRectVersion() {
        let point = SecretRegion.normalizedPoint(ofView: CGPoint(x: 200, y: 100), displaySize: CGSize(width: 800, height: 400))
        XCTAssertEqual(point, CGPoint(x: 0.25, y: 0.25))
    }

    // MARK: - Handle hit-testing

    func testHandleHitTestFindsTheNearestHandleWithinTolerance() {
        let region = SecretRegion(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let displaySize = CGSize(width: 400, height: 400)
        // topLeft sits at view point (100, 100); bottomRight at (300, 300).
        let hit = region.handle(at: CGPoint(x: 102, y: 98), displaySize: displaySize, tolerance: 10)
        XCTAssertEqual(hit, .topLeft)
    }

    func testHandleHitTestReturnsNilOutsideTolerance() {
        let region = SecretRegion(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let displaySize = CGSize(width: 400, height: 400)
        let hit = region.handle(at: CGPoint(x: 200, y: 200), displaySize: displaySize, tolerance: 10)
        XCTAssertNil(hit)
    }

    func testHandleHitTestDistinguishesAllEightHandles() {
        let region = SecretRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let displaySize = CGSize(width: 100, height: 100)
        for handle in SecretRegion.Handle.allCases {
            let point = CGPoint(x: handle.fraction.x * 100, y: handle.fraction.y * 100)
            XCTAssertEqual(region.handle(at: point, displaySize: displaySize, tolerance: 1), handle)
        }
    }

    // MARK: - Moving

    func testMovedTranslatesWithinBounds() {
        let moved = SecretRegion.moved(CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2), by: CGVector(dx: 0.1, dy: -0.1))
        XCTAssertEqual(moved.minX, 0.4, accuracy: 0.0001)
        XCTAssertEqual(moved.minY, 0.2, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.2, accuracy: 0.0001)
    }

    func testMovedClampsPositionButPreservesSize() {
        let moved = SecretRegion.moved(CGRect(x: 0.8, y: 0.1, width: 0.3, height: 0.2), by: CGVector(dx: 0.5, dy: 0))
        XCTAssertEqual(moved.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(moved.height, 0.2, accuracy: 0.0001)
        XCTAssertEqual(moved.maxX, 1, accuracy: 0.0001)
    }

    // MARK: - Rubber-band creation

    func testRubberBandFromTwoPointsIsOrderIndependent() {
        let forward = SecretRegion.rubberBand(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 70))
        let backward = SecretRegion.rubberBand(from: CGPoint(x: 110, y: 70), to: CGPoint(x: 10, y: 20))
        let expected = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(forward, expected)
        XCTAssertEqual(backward, expected)
    }

    // MARK: - Fitted frame (letterboxing)

    func testFittedFrameLetterboxesWiderContentHorizontallyCentered() {
        let frame = SecretRegion.fittedFrame(ofContentSize: CGSize(width: 200, height: 100), in: CGSize(width: 200, height: 200))
        XCTAssertEqual(frame, CGRect(x: 0, y: 50, width: 200, height: 100))
    }

    func testFittedFrameLetterboxesTallerContentVertically() {
        let frame = SecretRegion.fittedFrame(ofContentSize: CGSize(width: 100, height: 200), in: CGSize(width: 200, height: 200))
        XCTAssertEqual(frame, CGRect(x: 50, y: 0, width: 100, height: 200))
    }

    func testFittedFrameFillsContainerWhenAspectRatiosMatch() {
        let frame = SecretRegion.fittedFrame(ofContentSize: CGSize(width: 100, height: 50), in: CGSize(width: 200, height: 100))
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    // MARK: - Container <-> display point (zoom/pan)

    func testDisplayPointAtIdentityTransformUndoesOnlyLetterboxing() {
        let displayFrame = CGRect(x: 20, y: 0, width: 160, height: 200)
        let point = SecretRegion.displayPoint(
            ofContainerPoint: CGPoint(x: 30, y: 10),
            containerSize: CGSize(width: 200, height: 200),
            displayFrame: displayFrame,
            zoomScale: 1,
            zoomOffset: .zero
        )
        XCTAssertEqual(point, CGPoint(x: 10, y: 10))
    }

    func testContainerAndDisplayPointRoundTripUnderZoomAndPan() {
        let containerSize = CGSize(width: 400, height: 300)
        let displayFrame = CGRect(x: 50, y: 0, width: 300, height: 300)
        let zoomScale: CGFloat = 2.5
        let zoomOffset = CGSize(width: 30, height: -15)
        let original = CGPoint(x: 123, y: 87)

        let container = SecretRegion.containerPoint(
            ofDisplayPoint: original,
            containerSize: containerSize,
            displayFrame: displayFrame,
            zoomScale: zoomScale,
            zoomOffset: zoomOffset
        )
        let roundTripped = SecretRegion.displayPoint(
            ofContainerPoint: container,
            containerSize: containerSize,
            displayFrame: displayFrame,
            zoomScale: zoomScale,
            zoomOffset: zoomOffset
        )
        XCTAssertEqual(roundTripped.x, original.x, accuracy: 0.0001)
        XCTAssertEqual(roundTripped.y, original.y, accuracy: 0.0001)
    }
}

final class LoupeGeometryTests: XCTestCase {
    func testSourceRectSizedByPixelMagnification() {
        let rect = LoupeGeometry.sourceRect(
            normalizedCenter: CGPoint(x: 0.5, y: 0.5),
            imagePixelSize: CGSize(width: 1000, height: 1000),
            loupeDiameter: 120,
            pixelMagnification: 3
        )
        XCTAssertEqual(rect.width, 40, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 40, accuracy: 0.0001)
        XCTAssertEqual(rect.midX, 500, accuracy: 0.0001)
        XCTAssertEqual(rect.midY, 500, accuracy: 0.0001)
    }

    func testSourceRectClampsNearImageEdge() {
        let rect = LoupeGeometry.sourceRect(
            normalizedCenter: CGPoint(x: 0.01, y: 0.01),
            imagePixelSize: CGSize(width: 1000, height: 1000),
            loupeDiameter: 120,
            pixelMagnification: 3
        )
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertEqual(rect.width, 40, accuracy: 0.0001, "clamping to stay on-image must not shrink the crop")
    }

    func testEffectiveMagnificationScalesWithZoomAndFitRatio() {
        // A 3000px-wide scan fitted to 300pt (0.1 pt/px) at rest: "3x what's on screen" means
        // 3x that fit ratio, i.e. 0.3 pt/px — not a literal 3 pt/px, which would be a
        // pixel-peeping crop only ~40px wide regardless of the scan's actual resolution.
        let effective = LoupeGeometry.effectiveMagnification(
            3, zoomScale: 1, imagePixelSize: CGSize(width: 3000, height: 2000), displaySize: CGSize(width: 300, height: 200)
        )
        XCTAssertEqual(effective, 0.3, accuracy: 0.0001)
    }

    func testEffectiveMagnificationTracksCanvasZoom() {
        let atRest = LoupeGeometry.effectiveMagnification(
            3, zoomScale: 1, imagePixelSize: CGSize(width: 3000, height: 2000), displaySize: CGSize(width: 300, height: 200)
        )
        let zoomedIn = LoupeGeometry.effectiveMagnification(
            3, zoomScale: 2, imagePixelSize: CGSize(width: 3000, height: 2000), displaySize: CGSize(width: 300, height: 200)
        )
        XCTAssertEqual(zoomedIn, atRest * 2, accuracy: 0.0001, "pinching in should shrink the loupe's crop by the same factor, keeping it 3x the CURRENT on-screen appearance")
    }

    func testPositionFloatsAboveThePointWithGap() {
        let position = LoupeGeometry.position(
            for: CGPoint(x: 200, y: 200),
            containerSize: CGSize(width: 400, height: 400),
            diameter: 120,
            gap: 16
        )
        XCTAssertEqual(position, CGPoint(x: 200, y: 200 - 60 - 16))
    }

    func testPositionClampsToStayWithinContainerNearTopEdge() {
        let position = LoupeGeometry.position(
            for: CGPoint(x: 10, y: 5),
            containerSize: CGSize(width: 400, height: 400),
            diameter: 120,
            gap: 16
        )
        XCTAssertGreaterThanOrEqual(position.y, 60)
        XCTAssertGreaterThanOrEqual(position.x, 60)
    }

    // MARK: - Magnified region rect

    func testMagnifiedRectFillsTheLoupeWhenRegionMatchesTheSourceCrop() {
        // A region that exactly covers what the loupe cropped should exactly fill the
        // loupe's own drawing area (the same size the cropped image is drawn into).
        let sourceRect = CGRect(x: 480, y: 480, width: 40, height: 40)
        let rect = LoupeGeometry.magnifiedRect(
            ofNormalized: CGRect(x: 0.48, y: 0.48, width: 0.04, height: 0.04),
            imagePixelSize: CGSize(width: 1000, height: 1000),
            sourceRect: sourceRect,
            pixelMagnification: 3
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 120, height: 120))
    }

    func testMagnifiedRectPositionsRelativeToSourceRectOrigin() {
        let sourceRect = CGRect(x: 480, y: 480, width: 40, height: 40)
        let rect = LoupeGeometry.magnifiedRect(
            ofNormalized: CGRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02),
            imagePixelSize: CGSize(width: 1000, height: 1000),
            sourceRect: sourceRect,
            pixelMagnification: 3
        )
        XCTAssertEqual(rect, CGRect(x: 30, y: 30, width: 60, height: 60))
    }

    func testMagnifiedRectScalesWithPixelMagnification() {
        let sourceRect = CGRect(x: 480, y: 480, width: 40, height: 40)
        let rect = LoupeGeometry.magnifiedRect(
            ofNormalized: CGRect(x: 0.49, y: 0.49, width: 0.02, height: 0.02),
            imagePixelSize: CGSize(width: 1000, height: 1000),
            sourceRect: sourceRect,
            pixelMagnification: 6
        )
        XCTAssertEqual(rect, CGRect(x: 60, y: 60, width: 120, height: 120))
    }

    func testMagnifiedRectExtendsOutsideTheLoupeWhenRegionIsPartlyOffCrop() {
        // Not clamped: a region only partly within the crop maps to a rect that overhangs
        // the loupe's own bounds, relying on the caller's circular clip to trim it.
        let sourceRect = CGRect(x: 480, y: 480, width: 40, height: 40)
        let rect = LoupeGeometry.magnifiedRect(
            ofNormalized: CGRect(x: 0, y: 0, width: 0.01, height: 0.01),
            imagePixelSize: CGSize(width: 1000, height: 1000),
            sourceRect: sourceRect,
            pixelMagnification: 3
        )
        XCTAssertEqual(rect.minX, -1440, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, -1440, accuracy: 0.0001)
    }
}
