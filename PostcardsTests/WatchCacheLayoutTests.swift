import XCTest

final class WatchCacheLayoutTests: XCTestCase {
    private let supportDirectory = URL(fileURLWithPath: "/tmp/watch-support")

    func testCacheFileNameAppendsThePostcardsExtension() {
        XCTAssertEqual(WatchCacheLayout.cacheFileName(for: "Trip to Kyoto"), "Trip to Kyoto.postcards")
    }

    func testCacheURLNestsUnderPinnedCollections() {
        let url = WatchCacheLayout.cacheURL(for: "Trip to Kyoto", in: supportDirectory)
        XCTAssertEqual(url, supportDirectory.appendingPathComponent("PinnedCollections/Trip to Kyoto.postcards"))
    }

    func testCatalogFileURLIsDirectlyUnderSupportDirectory() {
        XCTAssertEqual(WatchCacheLayout.catalogFileURL(in: supportDirectory), supportDirectory.appendingPathComponent("watch-catalog.json"))
    }

    func testCatalogRoundTripsThroughEncodeAndDecode() throws {
        let catalog = [
            WatchCollectionInfo(id: "Trip to Kyoto", title: "Trip to Kyoto", cardCount: 12, coverThumbnail: Data([0x01, 0x02])),
            WatchCollectionInfo(id: "Postcards from Rome", title: "Postcards from Rome", cardCount: 4, coverThumbnail: nil),
        ]

        let data = try XCTUnwrap(WatchCacheLayout.encodeCatalog(catalog))
        let decoded = try XCTUnwrap(WatchCacheLayout.decodeCatalog(data))

        XCTAssertEqual(decoded, catalog)
    }

    func testDecodeCatalogReturnsNilForGarbageData() {
        XCTAssertNil(WatchCacheLayout.decodeCatalog(Data([0xFF, 0x00, 0x10])))
    }
}
