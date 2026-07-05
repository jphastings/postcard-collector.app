import XCTest

final class ParallaxGeometryTests: XCTestCase {
    // MARK: - Device motion mapping

    func testDeviceMotionZeroDeltaIsZeroTilt() {
        XCTAssertEqual(ParallaxGeometry.tilt(pitchDelta: 0, rollDelta: 0), .zero)
    }

    func testDeviceMotionClampsAtExtremes() {
        let tilt = ParallaxGeometry.tilt(pitchDelta: .pi, rollDelta: -.pi)
        XCTAssertEqual(tilt.y, ParallaxGeometry.maxDegrees)
        XCTAssertEqual(tilt.x, -ParallaxGeometry.maxDegrees)
    }

    func testDeviceMotionSignFollowsTheDelta() {
        let positive = ParallaxGeometry.tilt(pitchDelta: 0.1, rollDelta: 0.1)
        let negative = ParallaxGeometry.tilt(pitchDelta: -0.1, rollDelta: -0.1)
        XCTAssertGreaterThan(positive.x, 0)
        XCTAssertGreaterThan(positive.y, 0)
        XCTAssertLessThan(negative.x, 0)
        XCTAssertLessThan(negative.y, 0)
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
        let atEdge = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 100, y: 100), in: CGSize(width: 100, height: 100))
        XCTAssertEqual(atEdge.x, ParallaxGeometry.maxDegrees)
        XCTAssertEqual(atEdge.y, ParallaxGeometry.maxDegrees)

        let beyond = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 500, y: -500), in: CGSize(width: 100, height: 100))
        XCTAssertEqual(beyond.x, ParallaxGeometry.maxDegrees)
        XCTAssertEqual(beyond.y, -ParallaxGeometry.maxDegrees)
    }

    func testHoverSignFollowsThePointer() {
        let rightOfCentre = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 90, y: 50), in: CGSize(width: 100, height: 100))
        let leftOfCentre = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 10, y: 50), in: CGSize(width: 100, height: 100))
        XCTAssertGreaterThan(rightOfCentre.x, 0)
        XCTAssertLessThan(leftOfCentre.x, 0)

        let belowCentre = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 50, y: 90), in: CGSize(width: 100, height: 100))
        let aboveCentre = ParallaxGeometry.tilt(hoverLocation: CGPoint(x: 50, y: 10), in: CGSize(width: 100, height: 100))
        XCTAssertGreaterThan(belowCentre.y, 0)
        XCTAssertLessThan(aboveCentre.y, 0)
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
