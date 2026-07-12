import XCTest

/// Regression test for the grid/map mode switcher's placement on macOS: it used to be a
/// `NavigationSplitView` toolbar item whose position depended on the per-column toolbar
/// merge, and it drifted out to sit beside the (i)/search field instead of the content pane
/// it controls whenever another column's own toolbar contribution changed — see
/// `CollectionModeSwitcher`'s doc comment, which lists three separate regressions of this
/// kind. It's now rendered as a `.overlay` INSIDE the content pane instead of a toolbar item,
/// which should make this class of drift structurally impossible; this test pins that down.
///
/// macOS-only (this target only builds for `Postcards-macOS`): reuses the same
/// `-uitest-import` fixture-loading launch argument as `ImportedCollectionUITests`.
final class ModeSwitcherPlacementUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false

        let db = try XCTUnwrap(
            Bundle(for: ModeSwitcherPlacementUITests.self)
                .url(forResource: "user-collection", withExtension: "postcards"),
            "user-collection.postcards must be a UI-test bundle resource"
        )

        app = XCUIApplication()
        // macOS restores the previous session's window/split-view state, which can leave
        // the sidebar effectively collapsed (a prior run's saved 148pt frame is below the
        // sidebar's minimum) and hide the row this test waits for — launch stateless.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-uitest-import", db.path]
        app.launch()
    }

    @MainActor
    func testModeSwitcherStaysInsideContentPane() throws {
        // The import runs asynchronously at launch; the collection then appears in the
        // sidebar (identifier is the filename stem — see `SourceRow`).
        let sidebarRow = app.descendants(matching: .any).matching(identifier: "user-collection").firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 15), "imported collection never appeared in the sidebar")
        sidebarRow.click()

        // Regression check #1: the switcher must exist at all — if it were ever swallowed
        // into a toolbar's ">>" overflow menu, this element wouldn't be found on screen.
        let switcher = app.descendants(matching: .any).matching(identifier: "CollectionModeSwitcher").firstMatch
        XCTAssertTrue(
            switcher.waitForExistence(timeout: 15),
            "mode switcher never appeared — it may be hidden in a toolbar overflow menu"
        )

        // Regression check #2: it must sit INSIDE the content pane, not detached out toward
        // the detail column/window's trailing edge.
        //
        // Anchored on the detail pane's own leading edge (via the "DetailPane"
        // accessibility identifier on `LibraryView`'s detail column) rather than any
        // window-width fraction: at the window's 900pt minimum SwiftUI legitimately gives
        // the content column more than its ideal width, which broke a 75%-of-window
        // heuristic on CI while the switcher was exactly where it belonged.
        assertSwitcherIsWithinContentPane(switcher)

        // Re-check with a card selected too (the scenario the bug report/original three
        // regressions all involved — the detail column showing real content, not the "Select
        // a Postcard" placeholder).
        let anyCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'user-card-'"))
            .firstMatch
        XCTAssertTrue(anyCard.waitForExistence(timeout: 15), "no tappable card cells in the grid")
        anyCard.click()

        assertSwitcherIsWithinContentPane(switcher)
    }

    @MainActor
    private func assertSwitcherIsWithinContentPane(
        _ switcher: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let detailPane = app.descendants(matching: .any).matching(identifier: "DetailPane").firstMatch
        XCTAssertTrue(
            detailPane.waitForExistence(timeout: 10),
            "detail pane (identifier \"DetailPane\") not found to measure the switcher against",
            file: file,
            line: line
        )
        // A point of tolerance absorbs sub-pixel frame rounding.
        XCTAssertLessThanOrEqual(
            switcher.frame.maxX,
            detailPane.frame.minX + 1,
            "mode switcher drifted out of the content pane (trailing edge \(switcher.frame.maxX) "
                + "vs. the detail pane's leading edge \(detailPane.frame.minX))",
            file: file,
            line: line
        )
    }
}
