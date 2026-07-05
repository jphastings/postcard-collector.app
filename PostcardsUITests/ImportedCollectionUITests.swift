import XCTest

/// Regression tests for the "imported collection = dead grid" bugs: after importing a
/// user's own .postcards, the grid must scroll and its cards must open.
///
/// The system Files picker can't be driven reliably from XCUITest, so the app's
/// DEBUG-only `-uitest-import <path>` launch argument (see LibraryView) feeds the picked
/// URL into the exact same import pipeline the file importer / open panel / drag-drop
/// use. Everything after that point — sidebar, grid, scrolling, card taps — is exercised
/// through real UI events.
final class ImportedCollectionUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false

        let db = try XCTUnwrap(
            Bundle(for: ImportedCollectionUITests.self)
                .url(forResource: "user-collection", withExtension: "postcards"),
            "user-collection.postcards must be a UI-test bundle resource"
        )

        app = XCUIApplication()
        app.launchArguments += ["-uitest-import", db.path]
        app.launch()
    }

    @MainActor
    func testImportedCollectionScrollsAndOpensCards() throws {
        // Cells and sidebar rows are queried by accessibilityIdentifier (SourceRow uses
        // the filename stem, GridCell the card name): the visible text is a user-set
        // collection title and the cells are text-free thumbnails whose labels are
        // human-facing descriptions, so identifiers are the stable machine handle.

        // The import runs asynchronously at launch; the collection then appears in the
        // sidebar.
        let sidebarRow = app.descendants(matching: .any).matching(identifier: "user-collection").firstMatch
        XCTAssertTrue(sidebarRow.waitForExistence(timeout: 15), "imported collection never appeared in the sidebar")
        sidebarRow.tap()

        // The grid must actually show the imported collection's cards.
        let firstCard = app.descendants(matching: .any).matching(identifier: "user-card-01").firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 15), "imported collection's cards never appeared in the grid")

        // Bug 2 regression: the grid must scroll. With 12 cards on an iPhone some cells
        // start off-screen; swiping must move the visible cells.
        let before = firstCard.frame
        app.swipeUp()
        let moved = !firstCard.exists || firstCard.frame != before
        XCTAssertTrue(moved, "swiping did not scroll the grid")

        // Bug 3 regression: tapping a card must open the detail view (recognisable by
        // its Info toolbar button).
        let anyCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'user-card-'"))
            .firstMatch
        XCTAssertTrue(anyCard.waitForExistence(timeout: 5), "no tappable card cells in the grid")
        anyCard.tap()

        let infoButton = app.buttons["Info"]
        XCTAssertTrue(infoButton.waitForExistence(timeout: 15), "tapping a card did not open the detail view")
    }
}
