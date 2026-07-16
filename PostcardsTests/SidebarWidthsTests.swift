import XCTest

final class SidebarWidthsTests: XCTestCase {
    func testGridModeUsesTheNarrowBounds() {
        let bounds = SidebarWidths.bounds(for: .grid)
        XCTAssertEqual(bounds, SidebarWidths.Bounds(min: 320, ideal: 340, max: 400))
    }

    func testMapModeUsesTheWideBounds() {
        let bounds = SidebarWidths.bounds(for: .map)
        XCTAssertEqual(bounds, SidebarWidths.Bounds(min: 400, ideal: 500, max: 700))
    }

    func testMapModeIsNeverNarrowerThanGridMode() {
        let grid = SidebarWidths.bounds(for: .grid)
        let map = SidebarWidths.bounds(for: .map)
        XCTAssertGreaterThanOrEqual(map.min, grid.max, "map mode should never overlap grid mode's range")
    }
}
