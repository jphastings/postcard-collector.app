import XCTest

/// The aggregation glue behind "All collections" and Single-postcards search: Go `Library`
/// hits become entries whose references open in the detail pane exactly like grid taps.
final class MapCardEntryTests: XCTestCase {
    private func makeHit(source: String, name: String) -> LibraryHit {
        let json = """
        {"source":"\(source)","card":{"name":"\(name)","filename":"\(name).postcard.jpeg","mimetype":"image/jpeg","flip":"book","front_px_w":300,"front_px_h":200,"has_back":true},"snippet":"…"}
        """
        return try! JSONDecoder().decode(LibraryHit.self, from: Data(json.utf8))
    }

    func testCollectionHitBecomesAnInCollectionReference() {
        let entries = MapCardEntry.entries(fromHits: [makeHit(source: "/tmp/holiday.postcards", name: "card-a")])

        XCTAssertEqual(entries.count, 1)
        guard case .inCollection(let path, let summary) = entries[0].reference else {
            return XCTFail("a .postcards source must map to an in-collection reference")
        }
        XCTAssertEqual(path, "/tmp/holiday.postcards")
        XCTAssertEqual(summary.name, "card-a")
        XCTAssertEqual(entries[0].summary.name, "card-a")
    }

    func testBareFileHitBecomesABareFileReference() {
        let entries = MapCardEntry.entries(fromHits: [makeHit(source: "/tmp/card-b.postcard.jpeg", name: "card-b")])

        guard case .bareFile(let path, _) = entries[0].reference else {
            return XCTFail("a bare-file source must map to a bare-file reference")
        }
        XCTAssertEqual(path, "/tmp/card-b.postcard.jpeg")
    }

    func testHitOrderIsPreserved() {
        let entries = MapCardEntry.entries(fromHits: [
            makeHit(source: "/tmp/a.postcards", name: "first"),
            makeHit(source: "/tmp/b.postcards", name: "second"),
        ])
        XCTAssertEqual(entries.map(\.summary.name), ["first", "second"])
    }
}
