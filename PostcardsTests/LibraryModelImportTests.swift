import XCTest

/// Integration tests for the macOS open-in-place library: a collection picked from outside the
/// app is referenced where it lies (not copied), remembered by a bookmark that follows the file
/// if it moves and is dropped if it disappears.
@MainActor
final class LibraryModelImportTests: XCTestCase {
    private var pickedDirectory: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        pickedDirectory = FileManager.default.temporaryDirectory
            .appending(path: "LibraryModelImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: pickedDirectory, withIntermediateDirectories: true)
        // Isolated defaults per test so persisted bookmarks don't leak between runs.
        suiteName = "LibraryModelImportTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: pickedDirectory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Canonicalises a path for comparison — bookmark resolution returns `/private/var/…` where a
    /// freshly-built temp URL is `/var/…` (the same file via a symlink).
    private func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Stages the bundled fixture db in a directory outside the app bundle, standing in for a
    /// file-importer/open-panel URL.
    @discardableResult
    private func stagePickedCollection(named filename: String = "my-cards.postcards") throws -> URL {
        let fixture = try XCTUnwrap(
            Bundle(for: LibraryModelImportTests.self).url(forResource: "fixture", withExtension: "postcards"),
            "fixture.postcards must be a test bundle resource"
        )
        let picked = pickedDirectory.appending(path: filename)
        try FileManager.default.copyItem(at: fixture, to: picked)
        return picked
    }

    func testOpenedCollectionIsReferencedInPlaceAndUsable() async throws {
        let picked = try stagePickedCollection()
        let model = LibraryModel(defaults: defaults)

        await model.importSources(from: [picked])

        XCTAssertNil(model.importError)
        let source = try XCTUnwrap(model.sources.last)
        XCTAssertEqual(source.displayName, "my-cards")
        XCTAssertTrue(source.isCollection)
        XCTAssertEqual(source.path, picked.path, "must reference the picked file in place, not a copy")

        // Fully usable at its real location: list, thumbnail, and full image.
        let cards = try await GoCore.shared.cardSummaries(inCollectionAt: source.path)
        XCTAssertEqual(cards.count, 5)
        let thumbnail = try await GoCore.shared.thumbnail(forCard: cards[0].name, inCollectionAt: source.path)
        XCTAssertFalse(thumbnail.isEmpty)
        let image = try await GoCore.shared.image(forCard: cards[0].name, inCollectionAt: source.path)
        XCTAssertFalse(image.isEmpty)
    }

    func testOpenedSourcesPersistAcrossRelaunch() async throws {
        let picked = try stagePickedCollection()
        let first = LibraryModel(defaults: defaults)
        await first.importSources(from: [picked])
        XCTAssertNil(first.importError)

        // A brand-new model over the same defaults = app relaunch.
        let relaunched = LibraryModel(defaults: defaults)
        XCTAssertEqual(relaunched.sources.map(\.displayName), ["my-cards"])
        XCTAssertEqual(relaunched.sources.first.map { resolved($0.path) }, resolved(picked.path))
    }

    func testMovedFileFollowsToNewLocationOnRelaunch() async throws {
        let picked = try stagePickedCollection()
        await LibraryModel(defaults: defaults).importSources(from: [picked])

        // Move the file elsewhere, then relaunch — the bookmark should resolve to its new home.
        let moved = pickedDirectory.appending(path: "moved-cards.postcards")
        try FileManager.default.moveItem(at: picked, to: moved)

        let relaunched = LibraryModel(defaults: defaults)
        XCTAssertEqual(relaunched.sources.map { resolved($0.path) }, [resolved(moved.path)], "the reference must follow the moved file")
    }

    func testMissingFileIsDroppedOnRelaunch() async throws {
        let picked = try stagePickedCollection()
        await LibraryModel(defaults: defaults).importSources(from: [picked])

        // Delete the original — open-in-place can't recover it, so relaunch must drop the row.
        try FileManager.default.removeItem(at: picked)

        let relaunched = LibraryModel(defaults: defaults)
        XCTAssertTrue(relaunched.sources.isEmpty, "a file that can't be found must be dropped, not shown broken")
    }

    func testReopeningTheSameFileDoesNotDuplicate() async throws {
        let picked = try stagePickedCollection()
        let model = LibraryModel(defaults: defaults)

        await model.importSources(from: [picked])
        let countAfterFirst = model.sources.count
        await model.importSources(from: [picked])

        XCTAssertNil(model.importError)
        XCTAssertEqual(model.sources.count, countAfterFirst)
    }

    func testNonPostcardFileIsRejectedWithAVisibleError() async throws {
        let junk = pickedDirectory.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: junk)
        let model = LibraryModel(defaults: defaults)

        await model.importSources(from: [junk])

        XCTAssertNotNil(model.importError, "unusable picks must surface an error, never a silent dead grid")
        XCTAssertTrue(model.sources.isEmpty)
    }

    func testCorruptCollectionIsRejectedAtImportTime() async throws {
        let corrupt = pickedDirectory.appending(path: "broken.postcards")
        try Data("not a sqlite file".utf8).write(to: corrupt)
        let model = LibraryModel(defaults: defaults)

        await model.importSources(from: [corrupt])

        XCTAssertNotNil(model.importError)
        XCTAssertTrue(model.sources.isEmpty)
        // A rejected file must not be remembered as a source for the next launch.
        let relaunched = LibraryModel(defaults: defaults)
        XCTAssertTrue(relaunched.sources.isEmpty)
    }
}
