import XCTest

/// Coverage for the two-level sidebar restructure (3-column `NavigationSplitView` → 2-column,
/// with a `NavigationStack` inside the sidebar column pushing from a collections list to a
/// `CollectionBrowser`). Supersedes `ModeSwitcherPlacementUITests`, which only pinned down the
/// switcher's placement inside the old three-column layout — that layout, and the overlay/
/// tap-gesture hack it needed, are both gone (see `CollectionModeSwitcher`'s doc comment), so
/// this suite re-verifies the same placement invariant against the new push/pop navigation,
/// plus the window title and column-widening behaviour that came with it.
///
/// macOS-only (this target only builds for `Postcards-macOS`): reuses the same `-uitest-import`
/// fixture-loading launch argument as `ImportedCollectionUITests`. `user-collection.postcards`'s
/// fixture cards all carry a latitude/longitude, so `CollectionModeSwitcher` is enabled as soon
/// as the collection is opened — no need to wait out an async "does this collection have any
/// located cards" check before exercising Map mode.
final class SidebarBrowserUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false

        let db = try XCTUnwrap(
            Bundle(for: SidebarBrowserUITests.self)
                .url(forResource: "user-collection", withExtension: "postcards"),
            "user-collection.postcards must be a UI-test bundle resource"
        )

        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-uitest-import", db.path]
        app.launch()
    }

    /// Covers, in one launch: opening a collection shows the switcher and updates the window
    /// title (1); the switcher lands in the top titlebar band, clear of the pushed pane's own
    /// bottom search field, rather than the sidebar column's bottom bar; the pushed browser
    /// fills the sidebar column in both grid and map modes (2); clicking the switcher's Map
    /// button shows `CollectionMap` on the first click (3); the switcher never drifts out past
    /// the detail pane's leading edge (4); the back chevron returns to the collections list (5).
    ///
    /// Note: the *map-mode sidebar widening* (`SidebarWidths`) is deliberately NOT asserted here.
    /// macOS persists the split-divider position across launches and honours it OVER the
    /// mode-driven `.navigationSplitViewColumnWidth`, so whether a widen is observable depends on
    /// invisible saved state that `-ApplePersistenceIgnoreState` doesn't reset — an unreliable
    /// thing to gate CI on. The widen is a cosmetic nicety, not a correctness property; the
    /// column-width values themselves are unit-tested in `SidebarWidthsTests`.
    @MainActor
    func testSidebarBrowserNavigationModesAndModeSwitch() throws {
        let window = app.windows.firstMatch
        XCTAssertEqual(window.title, "Postcards", "level 1 (collections list) should show the app's generic title")

        openImportedCollection()
        expectTitle("user-collection", on: window)

        let switcher = modeSwitcherElement()
        XCTAssertTrue(
            switcher.waitForExistence(timeout: 15),
            "mode switcher never appeared — it may be hidden in a toolbar overflow menu"
        )
        let detailPane = app.descendants(matching: .any).matching(identifier: "DetailPane").firstMatch
        XCTAssertTrue(detailPane.waitForExistence(timeout: 10), "DetailPane not found to measure widths/placement against")

        assertSwitcherIsWithinContentPane(switcher, detailPane: detailPane)

        // Regression check: `CollectionBrowser`'s toolbar items must land in the TOP titlebar
        // band, not the sidebar column's bottom bar. Automatic-placement toolbar items on this
        // destination used to drop down there — underneath, and hidden/unclickable behind, the
        // pushed pane's own `BottomSearchBar` (a bottom `safeAreaInset`, not a real toolbar) —
        // see the `.navigation`/`.primaryAction` placements now forced in `LibraryView`. Frames
        // are in SCREEN coordinates (the window itself can sit anywhere on screen), so this has
        // to be measured relative to the window's own origin, not an absolute constant.
        XCTAssertLessThan(
            switcher.frame.minY, window.frame.minY + 60,
            "mode switcher isn't in the top titlebar band (switcher minY \(switcher.frame.minY), "
                + "window minY \(window.frame.minY)) — it may have dropped into the sidebar's bottom bar"
        )
        let searchField = app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "Search this collection"))
            .firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "bottom search field not found")
        XCTAssertFalse(
            switcher.frame.intersects(searchField.frame),
            "mode switcher overlaps the bottom search field (switcher \(switcher.frame), "
                + "search field \(searchField.frame)) — it landed in the sidebar's bottom bar behind it"
        )

        // Regression check: the pushed browser must FILL the sidebar column. macOS proposes a
        // `NavigationStack`-in-sidebar destination its IDEAL height rather than the column's
        // (see `SidebarDestinationFill` in LibraryView.swift), which collapsed the pushed pane
        // to just its bottom search bar's height, pinned at the very bottom of the column with
        // the grid squeezed invisibly behind the search field — so the first grid cell must
        // render in the top half of the window.
        let firstCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'user-card-'"))
            .firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 15), "no grid cells appeared in the pushed collection browser")
        XCTAssertLessThan(
            firstCell.frame.minY, window.frame.midY,
            "first grid cell isn't in the top half of the window (cell minY \(firstCell.frame.minY), "
                + "window midY \(window.frame.midY)) — the pushed browser collapsed to the bottom of the sidebar column"
        )

        clickModeSwitcherButton("Map")
        let map = app.descendants(matching: .any).matching(identifier: "CollectionMap").firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 15), "clicking the switcher's Map button never showed CollectionMap")

        // The same fill invariant in map mode: the map must occupy most of the column's
        // height, not a thin strip behind the search bar.
        XCTAssertGreaterThanOrEqual(
            map.frame.height, window.frame.height * 0.6,
            "CollectionMap is only \(map.frame.height)pt tall in a \(window.frame.height)pt window "
                + "— the pushed browser collapsed instead of filling the sidebar column"
        )
        assertSwitcherIsWithinContentPane(switcher, detailPane: detailPane)

        clickModeSwitcherButton("Grid")

        // Spike finding: the sidebar's own `NavigationStack` back button is a plain Button
        // labelled "Back" whose image is the "chevron.backward" system symbol. Some AX
        // configurations surface the symbol name as the element's identifier instead of (or
        // alongside) its label, so both are tried before giving up.
        var back = app.buttons["Back"]
        if !back.waitForExistence(timeout: 5) {
            back = app.descendants(matching: .any).matching(identifier: "chevron.backward").firstMatch
        }
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no back button found to return to the collections list")
        back.click()

        let allCollectionsRow = app.descendants(matching: .any).matching(identifier: "All collections").firstMatch
        XCTAssertTrue(allCollectionsRow.waitForExistence(timeout: 10), "collections list didn't reappear after going back")
    }

    /// Regression test for a crash cycling the sidebar column hidden→shown with a collection
    /// pushed: AppKit's constraint watchdog threw NSGenericException ("more Update Constraints
    /// in Window passes than there are views in the window") because the fill machinery's
    /// geometry `onChange` handlers wrote `@State` synchronously inside the layout transaction
    /// while the split view animated its edge insets — a same-frame feedback loop (see
    /// `SidebarDestinationFill`'s doc comment). Cycles the toggle in both grid and map modes
    /// and asserts the app survives with the browser geometry re-settled.
    @MainActor
    func testSidebarHideShowCyclesKeepBrowserAliveAndFilled() throws {
        let window = app.windows.firstMatch
        openImportedCollection()

        let firstCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'user-card-'"))
            .firstMatch
        XCTAssertTrue(firstCell.waitForExistence(timeout: 15), "no grid cells appeared in the pushed collection browser")

        cycleSidebarHiddenAndShown(times: 2)
        XCTAssertEqual(app.state, .runningForeground, "app died cycling the sidebar in grid mode")
        XCTAssertTrue(firstCell.waitForExistence(timeout: 10), "grid cells gone after sidebar hide/show in grid mode")
        XCTAssertLessThan(
            firstCell.frame.minY, window.frame.midY,
            "first grid cell not in the top half after sidebar hide/show — browser geometry didn't re-settle"
        )

        clickModeSwitcherButton("Map")
        let map = app.descendants(matching: .any).matching(identifier: "CollectionMap").firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 15), "CollectionMap never appeared")

        cycleSidebarHiddenAndShown(times: 2)
        XCTAssertEqual(app.state, .runningForeground, "app died cycling the sidebar in map mode")
        XCTAssertTrue(map.waitForExistence(timeout: 10), "map gone after sidebar hide/show in map mode")
        waitUntil(timeout: 10) { map.frame.height >= window.frame.height * 0.6 }
        XCTAssertGreaterThanOrEqual(
            map.frame.height, window.frame.height * 0.6,
            "map didn't refill the column after sidebar hide/show (map \(map.frame.height) vs window \(window.frame.height))"
        )
    }

    // MARK: - Helpers

    /// Hides and re-shows the sidebar column (⌃⌘S, the standard macOS toggle) the given
    /// number of full cycles, letting each animation settle.
    @MainActor
    private func cycleSidebarHiddenAndShown(times: Int) {
        for _ in 0..<times {
            app.typeKey("s", modifierFlags: [.control, .command])
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            app.typeKey("s", modifierFlags: [.control, .command])
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
    }


    @MainActor
    private func openImportedCollection() {
        ensureSidebarVisible()
        let sidebarRow = app.descendants(matching: .any).matching(identifier: "user-collection").firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 15), "imported collection never appeared in the sidebar")
        sidebarRow.click()
    }

    /// macOS restores the sidebar's collapsed/expanded state from an `NSSplitView` autosave that
    /// `-ApplePersistenceIgnoreState` does NOT reset, so a previous session (or another test) that
    /// left the sidebar hidden would otherwise make every collection row unreachable. If the
    /// window launched with the sidebar collapsed, its toolbar shows a "Show Sidebar" button —
    /// click it so the collections list is present before anything looks for a row.
    @MainActor
    private func ensureSidebarVisible() {
        let showSidebar = app.buttons["Show Sidebar"]
        if showSidebar.waitForExistence(timeout: 3) {
            showSidebar.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// Finds the `CollectionModeSwitcher` toolbar item by its accessibility identifier. Falls
    /// back to a label-based lookup for its "Grid"/"Map" child buttons: a toolbar item pushed
    /// into the window toolbar's ">>" overflow menu loses its `accessibilityIdentifier` in some
    /// AX configurations — only its visible title text survives there — so an identifier-only
    /// query could misreport a merely-overflowed switcher as missing entirely.
    @MainActor
    private func modeSwitcherElement() -> XCUIElement {
        let byIdentifier = app.descendants(matching: .any).matching(identifier: "CollectionModeSwitcher").firstMatch
        if byIdentifier.waitForExistence(timeout: 15) {
            return byIdentifier
        }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Grid' OR label == 'Map'"))
            .firstMatch
    }

    @MainActor
    private func clickModeSwitcherButton(_ label: String) {
        let switcher = modeSwitcherElement()
        let button = switcher.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(label) button not found inside the mode switcher")
        button.click()
    }

    @MainActor
    private func assertSwitcherIsWithinContentPane(
        _ switcher: XCUIElement,
        detailPane: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
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

    @MainActor
    private func expectTitle(_ title: String, on window: XCUIElement, timeout: TimeInterval = 10) {
        let predicate = NSPredicate(format: "title == %@", title)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: window)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "window title never became \"\(title)\" (was \"\(window.title)\")")
    }

    /// Polls a condition without a fixed sleep — used for the animated sidebar-width
    /// transition, whose exact duration isn't a contract this test should pin down.
    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
