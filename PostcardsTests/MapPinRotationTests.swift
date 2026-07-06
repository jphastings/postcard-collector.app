import XCTest

final class MapPinRotationTests: XCTestCase {
    func testEmptyGroupYieldsNothing() {
        XCTAssertNil(MapPinRotation.next(in: [String](), after: nil))
        XCTAssertNil(MapPinRotation.next(in: [String](), after: "elsewhere"))
    }

    func testNoCurrentSelectionStartsAtTheFirstCard() {
        XCTAssertEqual(MapPinRotation.next(in: ["a", "b", "c"], after: nil), "a")
    }

    func testSelectionOutsideTheGroupStartsAtTheFirstCard() {
        XCTAssertEqual(MapPinRotation.next(in: ["a", "b", "c"], after: "elsewhere"), "a")
    }

    func testSuccessiveClicksRotateThroughTheGroup() {
        let group = ["a", "b", "c"]
        XCTAssertEqual(MapPinRotation.next(in: group, after: "a"), "b")
        XCTAssertEqual(MapPinRotation.next(in: group, after: "b"), "c")
    }

    func testRotationWrapsAroundToTheFirstCard() {
        XCTAssertEqual(MapPinRotation.next(in: ["a", "b", "c"], after: "c"), "a")
    }

    func testSingleCardPinAlwaysOpensThatCard() {
        XCTAssertEqual(MapPinRotation.next(in: ["only"], after: nil), "only")
        XCTAssertEqual(MapPinRotation.next(in: ["only"], after: "only"), "only")
        XCTAssertEqual(MapPinRotation.next(in: ["only"], after: "elsewhere"), "only")
    }
}
