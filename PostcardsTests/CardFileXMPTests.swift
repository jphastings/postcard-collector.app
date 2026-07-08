import XCTest

/// Cross-checks `CardFileXMP`'s pure-Swift byte sniffing against real card bytes pulled out
/// of the bundled fixture collection via `CollectionReader` — no separate bare-file fixture
/// needed, since a card's stored bytes are the same file a bare `.postcard.*` would contain.
final class CardFileXMPTests: XCTestCase {
    private func reader() throws -> CollectionReader {
        let path = try XCTUnwrap(
            Bundle(for: CardFileXMPTests.self).url(forResource: "fixture", withExtension: "postcards"),
            "fixture.postcards must be a test bundle resource"
        ).path
        return try CollectionReader(path: path)
    }

    func testFlipMatchesSummaryForEveryCard() throws {
        let reader = try reader()
        let summaries = try reader.cardSummaries()
        XCTAssertFalse(summaries.isEmpty)

        for summary in summaries {
            let data = try reader.imageData(name: summary.name)
            XCTAssertEqual(CardFileXMP.flip(in: data), summary.flip, "flip mismatch for \(summary.name)")
        }
    }

    func testFrontPixelSizeMatchesSummaryForEveryCard() throws {
        let reader = try reader()
        let summaries = try reader.cardSummaries()

        for summary in summaries {
            let data = try reader.imageData(name: summary.name)
            let size = try XCTUnwrap(CardFileXMP.frontPixelSize(data: data, flip: summary.flip), "no size for \(summary.name)")
            XCTAssertEqual(Int(size.width), summary.frontPxW, "front width mismatch for \(summary.name)")
            XCTAssertEqual(Int(size.height), summary.frontPxH, "front height mismatch for \(summary.name)")
        }
    }

    func testNonPostcardDataHasNoFlip() {
        XCTAssertNil(CardFileXMP.flip(in: Data("just some random bytes, no xmp packet here".utf8)))
    }
}
