import XCTest

/// macOS smoke coverage for "Create a Postcard": ⌘N opens the create-postcard `Window` scene
/// (`PostcardsApp`'s `NewPostcardCommand`, inside the `.newItem` command group it replaces),
/// its key controls render, "Create Postcard" starts disabled (no front image or destination
/// chosen yet — see `CreatePostcardModel.blockingIssues`), and Cancel closes the window
/// without creating anything.
///
/// BLOCKED locally as of this writing: running this (and every other test in
/// `PostcardsUITests-macOS`, including the pre-existing `SidebarBrowserUITests` — confirmed
/// not specific to this file) fails to even launch the app, with "Early unexpected exit,
/// operation never finished bootstrapping... Test crashed with signal kill before establishing
/// connection." This is this machine's non-interactive automation session lacking the
/// Accessibility/Automation TCC grant XCUITest needs to drive another macOS app — there's no
/// user session available to satisfy the permission prompt. The iOS counterpart
/// (`PostcardsUITests/CreatePostcardUITests.swift`, run against an iPad simulator) hits no such
/// wall and passes. This suite should still run fine in CI/a normal interactive machine; it
/// just couldn't be verified running here.
final class CreatePostcardUITests: XCTestCase {
    private var app: XCUIApplication!

    @MainActor
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
    }

    @MainActor
    func testNewPostcardCommandOpensCreateFormWithExpectedControls() throws {
        app.typeKey("n", modifierFlags: .command)

        let window = createPostcardWindow()
        XCTAssertTrue(window.waitForExistence(timeout: 15), "⌘N never opened the \"Create a Postcard\" window")

        XCTAssertTrue(
            window.staticTexts["Drop scans of your postcard here"].waitForExistence(timeout: 5),
            "the postcard stage's empty drop zone never appeared"
        )
        XCTAssertTrue(window.textFields["Name"].exists, "name field never appeared")

        let createButton = window.buttons["Create Postcard"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Create Postcard button never appeared")
        XCTAssertFalse(createButton.isEnabled, "Create Postcard must start disabled with no front image/destination chosen")

        let cancelButton = window.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Cancel button never appeared")
        cancelButton.click()

        waitForNonexistence(of: createPostcardWindow(), timeout: 10, message: "Cancel should close the Create a Postcard window")
    }

    // MARK: - Helpers

    private func createPostcardWindow() -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == %@", "Create a Postcard")).firstMatch
    }

    private func waitForNonexistence(of element: XCUIElement, timeout: TimeInterval, message: String) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, message)
    }
}
