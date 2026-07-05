import XCTest

final class FlipGeometryTests: XCTestCase {
    func testAxisMappingMatchesTheReferenceCSS() {
        // formats/web/postcards.css: .flip-book -> rotateY, .flip-calendar -> rotateX,
        // .flip-right-hand -> rotate3d(1,1,0,...), .flip-left-hand -> rotate3d(-1,1,0,...).
        XCTAssertEqual(FlipGeometry.axis(for: .book), FlipAxis(x: 0, y: 1, z: 0))
        XCTAssertEqual(FlipGeometry.axis(for: .calendar), FlipAxis(x: 1, y: 0, z: 0))
        XCTAssertEqual(FlipGeometry.axis(for: .rightHand), FlipAxis(x: 1, y: 1, z: 0))
        XCTAssertEqual(FlipGeometry.axis(for: .leftHand), FlipAxis(x: -1, y: 1, z: 0))
    }

    func testNoneHasNoFlipAxis() {
        XCTAssertNil(FlipGeometry.axis(for: .none))
    }

    // MARK: - Face visibility (the mid-animation step function)

    func testShowsFrontCutsHardAtTheEdgeOnAngles() {
        XCTAssertTrue(FlipGeometry.showsFront(atDegrees: 0))
        XCTAssertTrue(FlipGeometry.showsFront(atDegrees: 89.9))
        XCTAssertFalse(FlipGeometry.showsFront(atDegrees: 90.1))
        XCTAssertFalse(FlipGeometry.showsFront(atDegrees: 179))
        XCTAssertFalse(FlipGeometry.showsFront(atDegrees: 180))
        XCTAssertFalse(FlipGeometry.showsFront(atDegrees: 269.9))
        XCTAssertTrue(FlipGeometry.showsFront(atDegrees: 270.1))
        XCTAssertTrue(FlipGeometry.showsFront(atDegrees: 359))
        XCTAssertTrue(FlipGeometry.showsFront(atDegrees: 360))
    }

    func testShowsFrontHandlesNegativeAndMultiRevolutionAngles() {
        // The tap gesture accumulates +180° forever, so angles beyond one revolution are
        // the steady state, not an edge case.
        XCTAssertTrue(FlipGeometry.showsFront(atDegrees: -45))
        XCTAssertFalse(FlipGeometry.showsFront(atDegrees: -90.1))
        XCTAssertFalse(FlipGeometry.showsFront(atDegrees: -180))
        XCTAssertFalse(FlipGeometry.showsFront(atDegrees: 540)) // 3rd half-turn = back
        XCTAssertTrue(FlipGeometry.showsFront(atDegrees: 720)) // 4th half-turn = front
        XCTAssertFalse(FlipGeometry.showsFront(atDegrees: 720 + 90.1))
        XCTAssertTrue(FlipGeometry.showsFront(atDegrees: 720 + 89.9))
    }

    func testTheBackFaceIsVisibleExactlyWhenTheFrontIsNot() {
        // The back face is mounted at (flip angle + 180°); it must show iff the front hides.
        for angle in stride(from: -360.0, through: 1080.0, by: 7.3) {
            XCTAssertNotEqual(
                FlipGeometry.showsFront(atDegrees: angle),
                FlipGeometry.showsFront(atDegrees: angle + 180),
                "front and back both \(FlipGeometry.showsFront(atDegrees: angle) ? "visible" : "hidden") at \(angle)°"
            )
        }
    }

    // MARK: - Physical sizing (both sides are the same piece of card)

    func testHandFlipBacksSwapDimensionsAtEqualArea() {
        let front = CGSize(width: 300, height: 200)

        for flip in [Flip.leftHand, .rightHand] {
            let back = FlipGeometry.backSize(forFrontSize: front, flip: flip)
            XCTAssertEqual(back, CGSize(width: 200, height: 300), "\(flip) back must be the front rotated 90°")
            XCTAssertEqual(back.width * back.height, front.width * front.height, "\(flip) sides must have identical area")
        }
    }

    func testHomorientedBacksKeepTheFrontsDimensions() {
        let front = CGSize(width: 300, height: 200)
        for flip in [Flip.book, .calendar, .none] {
            XCTAssertEqual(FlipGeometry.backSize(forFrontSize: front, flip: flip), front)
        }
    }

    func testBoundingSizeIsTheUnionSquareForHandFlipsOnly() {
        let front = CGSize(width: 300, height: 200)

        // The union of a centred 300x200 and 200x300 is a 300x300 square — the CSS
        // reference's aspect-ratio: 1/1 container.
        XCTAssertEqual(FlipGeometry.boundingSize(forFrontSize: front, flip: .leftHand), CGSize(width: 300, height: 300))
        XCTAssertEqual(FlipGeometry.boundingSize(forFrontSize: front, flip: .rightHand), CGSize(width: 300, height: 300))

        XCTAssertEqual(FlipGeometry.boundingSize(forFrontSize: front, flip: .book), front)
        XCTAssertEqual(FlipGeometry.boundingSize(forFrontSize: front, flip: .calendar), front)
        XCTAssertEqual(FlipGeometry.boundingSize(forFrontSize: front, flip: .none), front)
    }
}
