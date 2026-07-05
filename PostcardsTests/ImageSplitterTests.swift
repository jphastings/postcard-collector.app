import XCTest

private let red: (UInt8, UInt8, UInt8) = (255, 0, 0)
private let blue: (UInt8, UInt8, UInt8) = (0, 0, 255)
private let green = RGB(r: 0, g: 255, b: 0)
private let black = RGB(r: 0, g: 0, b: 0)

final class ImageSplitterTests: XCTestCase {
    func testNoneFlipReturnsWholeImageAsFrontWithNoBack() throws {
        let combined = makeTestImage(width: 2, height: 2) { _, _ in (10, 20, 30) }

        let result = try ImageSplitter.split(combined, flip: .none)

        XCTAssertNil(result.back)
        XCTAssertEqual(result.front.width, 2)
        XCTAssertEqual(result.front.height, 2)
    }

    func testHalvingPutsTheTopHalfInFrontAndBottomHalfInBack() throws {
        let width = 4, sideHeight = 4
        let combined = makeTestImage(width: width, height: sideHeight * 2) { _, y in
            y < sideHeight ? red : blue
        }

        let result = try ImageSplitter.split(combined, flip: .book)
        let back = try XCTUnwrap(result.back)

        XCTAssertEqual(result.front.height, sideHeight)
        XCTAssertEqual(back.height, sideHeight)
        XCTAssertEqual(topDownPixels(of: result.front)[0, 0], RGB(r: 255, g: 0, b: 0))
        XCTAssertEqual(topDownPixels(of: back)[0, 0], RGB(r: 0, g: 0, b: 255))
    }

    /// See ImageSplitter.swift's derivation comment: encode.go rotates a left-hand back
    /// 90° CCW before storing it, so decode (and this test) expects it un-rotated 90° CW.
    func testLeftHandUnRotatesTheBackClockwise() throws {
        let result = try ImageSplitter.split(markedCombined(), flip: .leftHand)
        let back = topDownPixels(of: try XCTUnwrap(result.back))

        // A clockwise quarter turn moves a top-left marker to the top-right.
        XCTAssertEqual(back[back.width - 1, 0], green, "expected the marker at the top-right after a CW rotation")
        XCTAssertEqual(back[0, 0], black)
        XCTAssertEqual(back[0, back.height - 1], black)
        XCTAssertEqual(back[back.width - 1, back.height - 1], black)
    }

    /// See ImageSplitter.swift's derivation comment: encode.go rotates a right-hand back
    /// 90° CW before storing it, so decode (and this test) expects it un-rotated 90° CCW.
    func testRightHandUnRotatesTheBackCounterclockwise() throws {
        let result = try ImageSplitter.split(markedCombined(), flip: .rightHand)
        let back = topDownPixels(of: try XCTUnwrap(result.back))

        // A counter-clockwise quarter turn moves a top-left marker to the bottom-left.
        XCTAssertEqual(back[0, back.height - 1], green, "expected the marker at the bottom-left after a CCW rotation")
        XCTAssertEqual(back[0, 0], black)
        XCTAssertEqual(back[back.width - 1, 0], black)
        XCTAssertEqual(back[back.width - 1, back.height - 1], black)
    }

    func testHandFlipsSwapTheBacksDimensionsButBookDoesNot() throws {
        let sideWidth = 8, sideHeight = 3
        let combined = makeTestImage(width: sideWidth, height: sideHeight * 2) { _, _ in (128, 128, 128) }

        let book = try ImageSplitter.split(combined, flip: .book)
        XCTAssertEqual(book.front.width, sideWidth)
        XCTAssertEqual(book.front.height, sideHeight)
        XCTAssertEqual(try XCTUnwrap(book.back).width, sideWidth)
        XCTAssertEqual(try XCTUnwrap(book.back).height, sideHeight)

        let leftHand = try ImageSplitter.split(combined, flip: .leftHand)
        XCTAssertEqual(leftHand.front.width, sideWidth, "the front is never rotated")
        XCTAssertEqual(try XCTUnwrap(leftHand.back).width, sideHeight, "the back's dimensions swap")
        XCTAssertEqual(try XCTUnwrap(leftHand.back).height, sideWidth)

        let rightHand = try ImageSplitter.split(combined, flip: .rightHand)
        XCTAssertEqual(try XCTUnwrap(rightHand.back).width, sideHeight)
        XCTAssertEqual(try XCTUnwrap(rightHand.back).height, sideWidth)
    }

    /// A 4x8 combined image: white front (top half) and a black back (bottom half) with a
    /// 2x2 green marker in the back's own top-left corner.
    private func markedCombined() -> CGImage {
        let width = 4, sideHeight = 4
        return makeTestImage(width: width, height: sideHeight * 2) { x, y in
            guard y >= sideHeight else { return (255, 255, 255) }
            let backY = y - sideHeight
            return (x < 2 && backY < 2) ? (0, 255, 0) : (0, 0, 0)
        }
    }
}
