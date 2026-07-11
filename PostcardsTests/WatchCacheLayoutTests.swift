import XCTest

final class WatchCacheLayoutTests: XCTestCase {
    private let supportDirectory = URL(fileURLWithPath: "/tmp/watch-support")

    // MARK: - Layout

    func testCollectionDirectoryNestsUnderCollectionsByID() {
        let url = WatchCacheLayout.collectionDirectory(id: "Trip to Kyoto", in: supportDirectory)
        XCTAssertEqual(url, supportDirectory.appendingPathComponent("Collections/Trip to Kyoto", isDirectory: true))
    }

    func testManifestURLIsInsideTheCollectionDirectory() {
        let url = WatchCacheLayout.manifestURL(id: "Trip to Kyoto", in: supportDirectory)
        XCTAssertEqual(url, supportDirectory.appendingPathComponent("Collections/Trip to Kyoto/manifest.json"))
    }

    func testCardsDirectoryIsInsideTheCollectionDirectory() {
        let url = WatchCacheLayout.cardsDirectory(id: "Trip to Kyoto", in: supportDirectory)
        XCTAssertEqual(url, supportDirectory.appendingPathComponent("Collections/Trip to Kyoto/cards", isDirectory: true))
    }

    func testCardBlobURLNestsUnderTheCardsDirectoryUsingTheSafeFileNamePlusTierAndSide() {
        let url = WatchCacheLayout.cardBlobURL(
            id: "Trip to Kyoto", cardName: "Front & Back", tier: WatchRelay.tierScreen, side: WatchRelay.sideFront, in: supportDirectory
        )
        let expected = WatchCacheLayout.cardsDirectory(id: "Trip to Kyoto", in: supportDirectory)
            .appendingPathComponent("\(WatchCacheLayout.safeCardFileName(for: "Front & Back"))-screen-front")
        XCTAssertEqual(url, expected)
    }

    func testCardBlobURLDiffersByTierAndSideForTheSameCard() {
        let screenFront = WatchCacheLayout.cardBlobURL(
            id: "Trip to Kyoto", cardName: "Front & Back", tier: WatchRelay.tierScreen, side: WatchRelay.sideFront, in: supportDirectory
        )
        let screenBack = WatchCacheLayout.cardBlobURL(
            id: "Trip to Kyoto", cardName: "Front & Back", tier: WatchRelay.tierScreen, side: WatchRelay.sideBack, in: supportDirectory
        )
        let zoomFront = WatchCacheLayout.cardBlobURL(
            id: "Trip to Kyoto", cardName: "Front & Back", tier: WatchRelay.tierZoom, side: WatchRelay.sideFront, in: supportDirectory
        )
        XCTAssertEqual(Set([screenFront, screenBack, zoomFront]).count, 3)
    }

    func testCatalogFileURLIsDirectlyUnderSupportDirectory() {
        XCTAssertEqual(WatchCacheLayout.catalogFileURL(in: supportDirectory), supportDirectory.appendingPathComponent("watch-catalog.json"))
    }

    // MARK: - safeCardFileName

    func testSafeCardFileNameIsStableForTheSameName() {
        XCTAssertEqual(WatchCacheLayout.safeCardFileName(for: "Postcard #1"), WatchCacheLayout.safeCardFileName(for: "Postcard #1"))
    }

    func testSafeCardFileNameContainsNoPathSeparatorsOrPunctuationThatWouldConfuseTheFilesystem() {
        let name = "Trip/to Kyoto: Front & Back?"
        let safe = WatchCacheLayout.safeCardFileName(for: name)
        XCTAssertFalse(safe.contains("/"))
        XCTAssertFalse(safe.isEmpty)
    }

    func testSafeCardFileNameDiffersForDifferentNames() {
        XCTAssertNotEqual(WatchCacheLayout.safeCardFileName(for: "Card A"), WatchCacheLayout.safeCardFileName(for: "Card B"))
    }

    func testSafeCardFileNameRoundTripsBackToTheOriginalNameThroughCardName() {
        for name in ["Trip/to Kyoto: Front & Back? 京都", "Postcard #1", "a", ""] {
            let safe = WatchCacheLayout.safeCardFileName(for: name)
            XCTAssertEqual(WatchCacheLayout.cardName(fromSafeFileName: safe), name)
        }
    }

    func testCardNameReturnsNilForFileNamesThatArentValidSafeNames() {
        XCTAssertNil(WatchCacheLayout.cardName(fromSafeFileName: "not valid base64url!!"))
    }

    // MARK: - cardBlobComponents

    func testCardBlobComponentsRoundTripsATierAndSideQualifiedBlobFileName() {
        for tier in [WatchRelay.tierScreen, WatchRelay.tierZoom] {
            for side in [WatchRelay.sideFront, WatchRelay.sideBack] {
                let url = WatchCacheLayout.cardBlobURL(id: "Trip to Kyoto", cardName: "Front & Back", tier: tier, side: side, in: supportDirectory)
                let components = WatchCacheLayout.cardBlobComponents(fromSafeFileName: url.lastPathComponent)
                XCTAssertEqual(components?.cardName, "Front & Back")
                XCTAssertEqual(components?.tier, tier)
                XCTAssertEqual(components?.side, side)
            }
        }
    }

    func testCardBlobComponentsReturnsNilForAnOldFormatFileNameWithNoTierSideSuffix() {
        let oldFormatFileName = WatchCacheLayout.safeCardFileName(for: "Front & Back")
        XCTAssertNil(WatchCacheLayout.cardBlobComponents(fromSafeFileName: oldFormatFileName))
    }

    // MARK: - Catalog

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

    // MARK: - Manifest

    func testManifestRoundTripsThroughEncodeAndDecode() throws {
        let manifest = [
            WatchCardMeta(name: "Front & Back", flip: .leftHand, frontPxW: 900, frontPxH: 600),
            WatchCardMeta(name: "Second Card", flip: .none, frontPxW: 800, frontPxH: 500),
        ]

        let data = try XCTUnwrap(WatchCacheLayout.encodeManifest(manifest))
        let decoded = try XCTUnwrap(WatchCacheLayout.decodeManifest(data))

        XCTAssertEqual(decoded, manifest)
    }

    func testDecodeManifestReturnsNilForGarbageData() {
        XCTAssertNil(WatchCacheLayout.decodeManifest(Data([0xFF, 0x00, 0x10])))
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
