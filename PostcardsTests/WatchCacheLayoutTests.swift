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
            WatchCollectionInfo(id: "Trip to Kyoto", title: "Trip to Kyoto", cardCount: 12),
            WatchCollectionInfo(id: "Postcards from Rome", title: "Postcards from Rome", cardCount: 4),
        ]

        let data = try XCTUnwrap(WatchCacheLayout.encodeCatalog(catalog))
        let decoded = try XCTUnwrap(WatchCacheLayout.decodeCatalog(data))

        XCTAssertEqual(decoded, catalog)
    }

    func testDecodeCatalogReturnsNilForGarbageData() {
        XCTAssertNil(WatchCacheLayout.decodeCatalog(Data([0xFF, 0x00, 0x10])))
    }

    // MARK: - idsToEvict

    func testIdsToEvictReturnsNothingWhenUnderTheLimit() {
        let dates: [String: Date] = ["a": .now, "b": .now.addingTimeInterval(-10)]
        XCTAssertEqual(WatchCacheLayout.idsToEvict(cachedModificationDates: dates, pinned: [], limit: 8), [])
    }

    func testIdsToEvictDropsTheOldestTemporaryFilesBeyondTheLimit() {
        let now = Date()
        let dates: [String: Date] = [
            "oldest": now.addingTimeInterval(-300),
            "older": now.addingTimeInterval(-200),
            "newer": now.addingTimeInterval(-100),
            "newest": now,
        ]
        XCTAssertEqual(
            WatchCacheLayout.idsToEvict(cachedModificationDates: dates, pinned: [], limit: 2),
            ["oldest", "older"]
        )
    }

    func testIdsToEvictNeverIncludesPinnedFilesRegardlessOfAge() {
        let now = Date()
        let dates: [String: Date] = [
            "pinned-old": now.addingTimeInterval(-300),
            "temp-old": now.addingTimeInterval(-200),
            "temp-new": now,
        ]
        XCTAssertEqual(
            WatchCacheLayout.idsToEvict(cachedModificationDates: dates, pinned: ["pinned-old"], limit: 1),
            ["temp-old"]
        )
    }

    func testIdsToEvictUsesTheDefaultTemporaryCacheLimit() {
        var dates: [String: Date] = [:]
        for index in 0..<(WatchCacheLayout.temporaryCacheLimit + 3) {
            dates["item-\(index)"] = Date(timeIntervalSince1970: TimeInterval(index))
        }
        let evicted = WatchCacheLayout.idsToEvict(cachedModificationDates: dates, pinned: [])
        XCTAssertEqual(evicted, ["item-0", "item-1", "item-2"])
    }
}
