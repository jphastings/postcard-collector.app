import XCTest

/// Integration tests for the import pipeline (the bugs-2/3 regression area): a collection
/// picked from OUTSIDE the app bundle must stay fully usable — list, thumbnails, full
/// images — because it's copied into the app container at import, not read in place
/// through a security-scoped URL whose grant can lapse.
@MainActor
final class LibraryModelImportTests: XCTestCase {
    private var importDirectory: URL!
    private var pickedDirectory: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "LibraryModelImportTests-\(UUID().uuidString)")
        importDirectory = base.appending(path: "imported")
        pickedDirectory = base.appending(path: "picked")
        try FileManager.default.createDirectory(at: pickedDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: importDirectory.deletingLastPathComponent())
    }

    /// Stages the bundled fixture db in a directory outside the app bundle/import dir,
    /// standing in for a file-importer/open-panel URL.
    private func stagePickedCollection(named filename: String = "my-cards.postcards") throws -> URL {
        let fixture = try XCTUnwrap(
            Bundle(for: LibraryModelImportTests.self).url(forResource: "fixture", withExtension: "postcards"),
            "fixture.postcards must be a test bundle resource"
        )
        let picked = pickedDirectory.appending(path: filename)
        try FileManager.default.copyItem(at: fixture, to: picked)
        return picked
    }

    func testImportedCollectionIsCopiedIntoContainerAndFullyUsable() async throws {
        let picked = try stagePickedCollection()
        let model = LibraryModel(importDirectory: importDirectory)
        let preexistingSources = model.sources.count

        await model.importSources(from: [picked])

        XCTAssertNil(model.importError)
        XCTAssertEqual(model.sources.count, preexistingSources + 1)
        let source = try XCTUnwrap(model.sources.last)
        XCTAssertEqual(source.displayName, "my-cards")
        XCTAssertTrue(source.isCollection)
        XCTAssertTrue(source.path.hasPrefix(importDirectory.path), "must open the container copy, not the picked file")

        // Delete the original — the app must keep working from its own copy (this is
        // exactly what a lapsed security-scope grant looked like to the Go core).
        try FileManager.default.removeItem(at: picked)

        let cards = try await GoCore.shared.cardSummaries(inCollectionAt: source.path)
        XCTAssertEqual(cards.count, 5)

        let thumbnail = try await GoCore.shared.thumbnail(forCard: cards[0].name, inCollectionAt: source.path)
        XCTAssertFalse(thumbnail.isEmpty)

        let image = try await GoCore.shared.image(forCard: cards[0].name, inCollectionAt: source.path)
        XCTAssertFalse(image.isEmpty)
    }

    func testImportedSourcesAreRestoredOnRelaunch() async throws {
        let picked = try stagePickedCollection()
        let first = LibraryModel(importDirectory: importDirectory)
        await first.importSources(from: [picked])
        XCTAssertNil(first.importError)

        // A brand-new model over the same container dir = app relaunch. (The test bundle
        // has no bundled fixtures, so restored imports are the only sources; avoid path
        // prefix checks — /var vs /private/var symlinks differ between APIs.)
        let relaunched = LibraryModel(importDirectory: importDirectory)
        XCTAssertEqual(relaunched.sources.map(\.displayName), ["my-cards"])
    }

    func testReimportingTheSameFilenameReplacesRatherThanDuplicates() async throws {
        let picked = try stagePickedCollection()
        let model = LibraryModel(importDirectory: importDirectory)

        await model.importSources(from: [picked])
        let countAfterFirst = model.sources.count
        await model.importSources(from: [picked])

        XCTAssertNil(model.importError)
        XCTAssertEqual(model.sources.count, countAfterFirst)
    }

    func testNonPostcardFileIsRejectedWithAVisibleError() async throws {
        let junk = pickedDirectory.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: junk)
        let model = LibraryModel(importDirectory: importDirectory)
        let preexistingSources = model.sources.count

        await model.importSources(from: [junk])

        XCTAssertNotNil(model.importError, "unusable picks must surface an error, never a silent dead grid")
        XCTAssertEqual(model.sources.count, preexistingSources)
    }

    func testCorruptCollectionIsRejectedAtImportTime() async throws {
        let corrupt = pickedDirectory.appending(path: "broken.postcards")
        try Data("not a sqlite file".utf8).write(to: corrupt)
        let model = LibraryModel(importDirectory: importDirectory)
        let preexistingSources = model.sources.count

        await model.importSources(from: [corrupt])

        XCTAssertNotNil(model.importError)
        XCTAssertEqual(model.sources.count, preexistingSources)
        // The failed copy must not linger to be "restored" as a broken source next launch.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: importDirectory.path)) ?? []
        XCTAssertFalse(leftovers.contains("broken.postcards"))
    }
}
