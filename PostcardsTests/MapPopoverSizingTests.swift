import XCTest

final class MapPopoverSizingTests: XCTestCase {
    func testCapsAtSixRowsWhenTheMapIsTall() {
        // Half of a tall map comfortably exceeds six rows, so the row-count cap wins.
        let sixRows = CGFloat(MapPopoverSizing.maxVisibleRows) * MapPopoverSizing.approximateRowHeight
        XCTAssertEqual(MapPopoverSizing.maxHeight(forAvailableHeight: 2000), sixRows)
    }

    func testCapsAtAFractionOfAvailableHeightWhenTheMapIsShort() {
        // A short map's fraction is well under six rows, so the map-height cap wins.
        XCTAssertEqual(MapPopoverSizing.maxHeight(forAvailableHeight: 100), 100 * MapPopoverSizing.maxHeightFraction)
    }

    func testAlwaysTheSmallerOfTheTwoCaps() {
        for height: CGFloat in [0, 50, 150, 384, 400, 1000] {
            let result = MapPopoverSizing.maxHeight(forAvailableHeight: height)
            let sixRows = CGFloat(MapPopoverSizing.maxVisibleRows) * MapPopoverSizing.approximateRowHeight
            let fraction = height * MapPopoverSizing.maxHeightFraction
            XCTAssertEqual(result, min(sixRows, fraction))
        }
    }

    func testNonPositiveOrNonFiniteHeightYieldsZero() {
        XCTAssertEqual(MapPopoverSizing.maxHeight(forAvailableHeight: 0), 0)
        XCTAssertEqual(MapPopoverSizing.maxHeight(forAvailableHeight: -50), 0)
        XCTAssertEqual(MapPopoverSizing.maxHeight(forAvailableHeight: .nan), 0)
        XCTAssertEqual(MapPopoverSizing.maxHeight(forAvailableHeight: .infinity), CGFloat(MapPopoverSizing.maxVisibleRows) * MapPopoverSizing.approximateRowHeight)
    }
}
