import XCTest

/// iPad smoke coverage for "Create a Postcard": the (+) toolbar item becomes a `Menu` on iPad
/// (`AddMenu`, see `LibraryView.swift`) offering "Create Postcard…"/"Open Postcard…"; tapping
/// Create presents `CreatePostcardForm` as a `fullScreenCover`, and Cancel dismisses it.
/// iPhone-only behaviour (the plain, menu-less Add button `AddMenu` falls back to there) isn't
/// covered here — this suite must run on an iPad destination.
final class CreatePostcardUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @MainActor
    func testAddMenuOffersCreateAndOpenThenCreatePresentsFullScreenForm() throws {
        ensureSidebarVisible()

        let addButton = app.buttons["Add…"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 15), "(+) toolbar item never appeared")
        addButton.tap()

        let createMenuItem = app.buttons["Create Postcard…"]
        let openMenuItem = app.buttons["Open Postcard…"]
        XCTAssertTrue(createMenuItem.waitForExistence(timeout: 5), "menu never showed \"Create Postcard…\"")
        XCTAssertTrue(openMenuItem.exists, "menu never showed \"Open Postcard…\"")

        createMenuItem.tap()

        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Create Postcard… never presented the full-screen form")

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Cancel button never appeared")
        cancelButton.tap()
        XCTAssertFalse(nameField.waitForExistence(timeout: 5), "Cancel should dismiss the create-postcard form")
    }

    // MARK: - Helpers

    /// The (+) menu lives in the sidebar's own toolbar (`LibraryView.swift`), so it's absent
    /// whenever the split view launches with the sidebar column collapsed — this iPad
    /// simulator does, in portrait, on a fresh launch — exactly the case
    /// `SidebarBrowserUITests.ensureSidebarVisible` handles on macOS.
    @MainActor
    private func ensureSidebarVisible() {
        let showSidebar = app.buttons["Show Sidebar"]
        if showSidebar.waitForExistence(timeout: 5) {
            showSidebar.tap()
        }
    }
}
