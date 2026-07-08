import XCTest

/// Equivalence tests against the Go core: `CollectionReader` is a native, Go-free
/// replacement for `AppcoreCollection`, so it must read the exact same bundled fixture
/// identically to `GoCore` (which is available in this test target for comparison).
final class CollectionReaderTests: XCTestCase {
    private func fixturePath() throws -> String {
        try XCTUnwrap(
            Bundle(for: CollectionReaderTests.self).url(forResource: "fixture", withExtension: "postcards"),
            "fixture.postcards must be a test bundle resource"
        ).path
    }

    func testTitleMatchesGoCore() async throws {
        let path = try fixturePath()
        let reader = try CollectionReader(path: path)

        let goTitle = try await GoCore.shared.title(ofCollectionAt: path)
        XCTAssertEqual(try reader.title(), goTitle)
    }

    func testCardSummariesMatchGoCoreNamesFlipsAndOrder() async throws {
        let path = try fixturePath()
        let reader = try CollectionReader(path: path)

        let goSummaries = try await GoCore.shared.cardSummaries(inCollectionAt: path)
        let nativeSummaries = try reader.cardSummaries()

        XCTAssertEqual(nativeSummaries.map(\.name), goSummaries.map(\.name))
        XCTAssertEqual(nativeSummaries.map(\.flip), goSummaries.map(\.flip))
        XCTAssertEqual(nativeSummaries.map(\.hasBack), goSummaries.map(\.hasBack))
        XCTAssertEqual(nativeSummaries.map(\.sentOn), goSummaries.map(\.sentOn))
        XCTAssertEqual(nativeSummaries.map(\.senderName), goSummaries.map(\.senderName))
        XCTAssertEqual(nativeSummaries.map(\.recipientName), goSummaries.map(\.recipientName))
        XCTAssertEqual(nativeSummaries.map(\.locationName), goSummaries.map(\.locationName))
        XCTAssertEqual(nativeSummaries.map(\.countryCode), goSummaries.map(\.countryCode))
        XCTAssertEqual(nativeSummaries.map(\.frontPxW), goSummaries.map(\.frontPxW))
        XCTAssertEqual(nativeSummaries.map(\.frontPxH), goSummaries.map(\.frontPxH))
        XCTAssertFalse(nativeSummaries.isEmpty)
    }

    func testCardSummariesOnlySetCoordinatesWhenBothLatitudeAndLongitudePresent() throws {
        let reader = try CollectionReader(path: try fixturePath())
        let summaries = try reader.cardSummaries()

        for summary in summaries {
            XCTAssertEqual(summary.latitude != nil, summary.longitude != nil, "\(summary.name) should have both or neither coordinate")
        }
        XCTAssertTrue(summaries.contains { $0.latitude != nil })
    }

    func testMetadataMatchesGoCoreForOneCard() async throws {
        let path = try fixturePath()
        let reader = try CollectionReader(path: path)
        let cardName = try XCTUnwrap(reader.cardSummaries().first).name

        let goMetadata = try await GoCore.shared.metadata(forCard: cardName, inCollectionAt: path)
        let nativeMetadata = try reader.metadata(name: cardName)

        XCTAssertEqual(nativeMetadata, goMetadata)
    }

    func testThumbnailAndImageDataAreNonEmpty() throws {
        let reader = try CollectionReader(path: try fixturePath())
        let cardName = try XCTUnwrap(reader.cardSummaries().first).name

        XCTAssertFalse(try reader.thumbnail(name: cardName).isEmpty)
        XCTAssertFalse(try reader.imageData(name: cardName).isEmpty)
    }

    func testUnknownCardNameThrowsNotFound() throws {
        let reader = try CollectionReader(path: try fixturePath())

        XCTAssertThrowsError(try reader.imageData(name: "no-such-card")) { error in
            guard case CollectionReaderError.notFound(let name) = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
            XCTAssertEqual(name, "no-such-card")
        }
    }

    func testOpeningANonCollectionFileFails() throws {
        let junk = FileManager.default.temporaryDirectory.appending(path: "not-a-collection-\(UUID().uuidString).postcards")
        try Data("not a sqlite file".utf8).write(to: junk)
        addTeardownBlock { try? FileManager.default.removeItem(at: junk) }

        XCTAssertThrowsError(try CollectionReader(path: junk.path))
    }
}
