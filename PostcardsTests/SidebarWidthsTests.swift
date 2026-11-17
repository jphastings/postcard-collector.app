import XCTest

final class SidebarWidthsTests: XCTestCase {
    func testGridModeUsesTheNarrowBounds() {
        let bounds = SidebarWidths.bounds(for: .grid)
        XCTAssertEqual(bounds, SidebarWidths.Bounds(min: 270, ideal: 340, max: 400))
    }

    func testMapModeUsesTheWideBounds() {
        let bounds = SidebarWidths.bounds(for: .map)
        XCTAssertEqual(bounds, SidebarWidths.Bounds(min: 300, ideal: 500, max: 700))
    }

    func testMapModeWidensTheColumn() {
        let grid = SidebarWidths.bounds(for: .grid)
        let map = SidebarWidths.bounds(for: .map)
        XCTAssertGreaterThanOrEqual(map.min, grid.min)
        XCTAssertGreaterThan(map.ideal, grid.max, "entering map mode should widen the column")
    }

    // MARK: - SidebarFit

    private let mapNeeds = SidebarFit.requiredWidth(for: .map)

    func testNarrowingPastTheFitCollapsesAShownSidebar() {
        let action = SidebarFit.afterResize(from: mapNeeds, to: mapNeeds - 1, mode: .map, sidebarShown: true, autoCollapsed: false)
        XCTAssertEqual(action, .collapseSidebar)
    }

    func testWideningBackRestoresOnlyASidebarThatWasCollapsedForSpace() {
        XCTAssertEqual(
            SidebarFit.afterResize(from: mapNeeds - 1, to: mapNeeds, mode: .map, sidebarShown: false, autoCollapsed: true),
            .restoreSidebar
        )
        XCTAssertEqual(
            SidebarFit.afterResize(from: mapNeeds - 1, to: mapNeeds, mode: .map, sidebarShown: false, autoCollapsed: false),
            .none,
            "a sidebar the user hid stays hidden"
        )
    }

    func testShowingTheSidebarInANarrowWindowGrowsTheWindowByTheShortfall() {
        XCTAssertEqual(SidebarFit.afterSidebarChange(width: mapNeeds - 50, mode: .map, sidebarShown: true), .growWindow(by: 50))
        XCTAssertEqual(SidebarFit.afterSidebarChange(width: mapNeeds, mode: .map, sidebarShown: true), .none)
        XCTAssertEqual(SidebarFit.afterSidebarChange(width: 100, mode: .map, sidebarShown: false), .none)
    }

    func testAnOpenInspectorNeedsRoomToo() {
        let action = SidebarFit.afterResize(
            from: mapNeeds + 10, to: mapNeeds, mode: .map, detailExtra: 260, sidebarShown: true, autoCollapsed: false
        )
        XCTAssertEqual(action, .collapseSidebar)
        XCTAssertEqual(
            SidebarFit.afterSidebarChange(width: mapNeeds, mode: .map, detailExtra: 260, sidebarShown: true),
            .growWindow(by: 260)
        )
    }
}
