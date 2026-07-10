import XCTest

/// Covers `WatchCatalogBuilder`'s pure entry construction — no `WatchConnectivity` involved,
/// so this exercises the same logic `WatchConnectivityProvider` (iOS only) uses to build the
/// catalog it pushes to the watch.
final class WatchCatalogBuilderTests: XCTestCase {
    private func fixturePath() throws -> String {
        try XCTUnwrap(
            Bundle(for: WatchCatalogBuilderTests.self).url(forResource: "fixture", withExtension: "postcards"),
            "fixture.postcards must be a test bundle resource"
        ).path
    }

    func testItemWithNoReaderFallsBackToDisplayNameWithNoCardsOrThumbnail() {
        let item = CloudItem(path: "/cloud/trip.postcards", displayName: "trip", isCollection: true, downloadState: .remote)

        let entry = WatchCatalogBuilder.entry(for: item, reader: nil)

        XCTAssertEqual(entry.id, "trip")
        XCTAssertEqual(entry.title, "trip")
        XCTAssertEqual(entry.cardCount, 0)
        XCTAssertNil(entry.coverThumbnail)
    }

    func testItemWithAReaderUsesItsTitleCountAndFirstCardsThumbnail() throws {
        let path = try fixturePath()
        let readerForExpectations = try CollectionReader(path: path)
        let expectedSummaries = try readerForExpectations.cardSummaries()
        let expectedTitle = try XCTUnwrap(readerForExpectations.title())
        let expectedThumbnail = try readerForExpectations.thumbnail(name: try XCTUnwrap(expectedSummaries.first).name)

        let item = CloudItem(path: path, displayName: "trip", isCollection: true, downloadState: .current)
        let entry = WatchCatalogBuilder.entry(for: item, reader: try CollectionReader(path: path))

        XCTAssertEqual(entry.id, "trip", "id always keys off displayName, never the reader's title")
        XCTAssertEqual(entry.title, expectedTitle)
        XCTAssertEqual(entry.cardCount, expectedSummaries.count)
        XCTAssertEqual(entry.coverThumbnail, expectedThumbnail)
    }
}
