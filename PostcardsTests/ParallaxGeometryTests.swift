import XCTest

/// Sign convention under test (see ParallaxGeometry's doc comment): positive `x` recedes
/// the card's RIGHT edge, positive `y` recedes the card's TOP edge. Both mappings must be
/// consistent across axes: the edge under the pointer recedes, and a device edge tilted
/// away tilts the card's same edge away.
final class ParallaxGeometryTests: XCTestCase {
    // MARK: - Device motion mapping

    func testDeviceMotionZeroDeltaIsZeroTilt() {
        XCTAssertEqual(ParallaxGeometry.tilt(pitchDelta: 0, rollDelta: 0), .zero)
    }

    func testDeviceMotionClampsAtExtremes() {
        let tilt = ParallaxGeometry.tilt(pitchDelta: .pi, rollDelta: -.pi)
        XCTAssertEqual(tilt.y, -ParallaxGeometry.maxDegrees)
        XCTAssertEqual(tilt.x, -ParallaxGeometry.maxDegrees)
    }

    func testDeviceMotionCardMimicsThePhone() {
        // CoreMotion's positive pitch brings the device's TOP edge toward the viewer, so
        // the card's top must come nearer too: negative y. Positive roll turns the
        // device's right edge away, so the card's right edge recedes: positive x.
        // Regression test for the inverted vertical axis — pitch and y have OPPOSITE signs.
        let topTowardViewer = ParallaxGeometry.tilt(pitchDelta: 0.1, rollDelta: 0.1)
        let topAwayFromViewer = ParallaxGeometry.tilt(pitchDelta: -0.1, rollDelta: -0.1)
        XCTAssertGreaterThan(topTowardViewer.x, 0)
        XCTAssertLessThan(topTowardViewer.y, 0, "device top toward viewer must bring the card's top nearer")
        XCTAssertLessThan(topAwayFromViewer.x, 0)
        XCTAssertGreaterThan(topAwayFromViewer.y, 0, "device top tilted away must recede the card's top")
    }

    func testDeviceMotionReduceMotionIsAlwaysZero() {
        XCTAssertEqual(ParallaxGeometry.tilt(pitchDelta: 1, rollDelta: 1, reduceMotion: true), .zero)
    }

    // MARK: - Hover mapping

    func testHoverAtCentreIsZero() {
        let tilt = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 50, y: 50), in: CGSize(width: 100, height: 100))
        XCTAssertEqual(tilt, .zero)
    }

    func testHoverClampsAtEdgesAndBeyond() {
        // Bottom-right corner: right edge recedes (+x), bottom edge recedes (−y).
        let atEdge = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 100, y: 100), in: CGSize(width: 100, height: 100))
        XCTAssertEqual(atEdge.x, ParallaxGeometry.maxDegrees)
        XCTAssertEqual(atEdge.y, -ParallaxGeometry.maxDegrees)

        let beyond = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 500, y: -500), in: CGSize(width: 100, height: 100))
        XCTAssertEqual(beyond.x, ParallaxGeometry.maxDegrees)
        XCTAssertEqual(beyond.y, ParallaxGeometry.maxDegrees)
    }

    func testHoverEdgeUnderThePointerRecedes() {
        // Regression test for the inverted vertical axis: all four edges must behave the
        // same way — the edge nearest the pointer tilts away from the viewer.
        let rightOfCentre = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 90, y: 50), in: CGSize(width: 100, height: 100))
        let leftOfCentre = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 10, y: 50), in: CGSize(width: 100, height: 100))
        XCTAssertGreaterThan(rightOfCentre.x, 0, "pointer at the right must recede the right edge")
        XCTAssertLessThan(leftOfCentre.x, 0, "pointer at the left must recede the left edge")

        let belowCentre = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 50, y: 90), in: CGSize(width: 100, height: 100))
        let aboveCentre = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 50, y: 10), in: CGSize(width: 100, height: 100))
        XCTAssertLessThan(belowCentre.y, 0, "pointer at the bottom must recede the bottom edge")
        XCTAssertGreaterThan(aboveCentre.y, 0, "pointer at the top must recede the top edge")
    }

    func testHoverDegenerateSizeIsZero() {
        XCTAssertEqual(ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 10, y: 10), in: .zero), .zero)
    }

    func testHoverReduceMotionIsAlwaysZero() {
        let tilt = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 0, y: 0), in: CGSize(width: 100, height: 100), reduceMotion: true)
        XCTAssertEqual(tilt, .zero)
    }

    // MARK: - Reference decay (slow re-centring so drift doesn't accumulate)

    func testDecayMovesPartwayTowardCurrent() {
        XCTAssertEqual(ParallaxGeometry.decay(reference: 0, towardCurrent: 1, factor: 0.5), 0.5, accuracy: 0.0001)
    }

    func testDecayWithZeroFactorDoesNotMove() {
        XCTAssertEqual(ParallaxGeometry.decay(reference: 0.2, towardCurrent: 1, factor: 0), 0.2, accuracy: 0.0001)
    }

    func testDecayWithFactorOneJumpsToCurrent() {
        XCTAssertEqual(ParallaxGeometry.decay(reference: 0.2, towardCurrent: 1, factor: 1), 1, accuracy: 0.0001)
    }
}
