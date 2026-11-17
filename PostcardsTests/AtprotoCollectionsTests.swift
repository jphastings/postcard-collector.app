import XCTest

final class AtprotoCollectionsTests: XCTestCase {
    private let collectionJSON = """
        {"uri": "at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/org.dotpostcard.collection/3lbq2xxbkzk2c",
         "cid": "bafyreie5737gdxlw5i64vzichcalba3z2v5n6icifvx5xytvske7mr3hpm",
         "title": "Summer 2024", "cardCount": 2, "createdAt": "2024-09-01T12:34:56.789Z",
         "postcards": ["at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/org.dotpostcard.postcard/3lbq2wcmaqs2a",
                       "at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/org.dotpostcard.postcard/3lbq2wdndq22b"]}
        """

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testCollectionDecodes() throws {
        let collection = try decode(AtprotoCollection.self, collectionJSON)
        XCTAssertEqual(collection.title, "Summer 2024")
        XCTAssertEqual(collection.cardCount, 2)
        XCTAssertEqual(collection.postcards.last, "at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/org.dotpostcard.postcard/3lbq2wdndq22b")
    }

    func testCollectionListsDecodeIncludingEmpty() throws {
        XCTAssertEqual(try decode([AtprotoCollection].self, "[\(collectionJSON)]").map(\.cid), ["bafyreie5737gdxlw5i64vzichcalba3z2v5n6icifvx5xytvske7mr3hpm"])
        XCTAssertEqual(try decode([AtprotoCollection].self, "[]"), [])
    }

    func testFollowsDecode() throws {
        let follows = try decode([AtprotoFollow].self, """
            [{"uri": "at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/org.dotpostcard.follow/3lbq3aaaaaa2c",
              "subject": "did:plc:z72i7hdynmk6r22z27h6tvur", "createdAt": "2024-09-02T08:00:00Z"}]
            """)
        XCTAssertEqual(follows.map(\.subject), ["did:plc:z72i7hdynmk6r22z27h6tvur"])
    }

    func testFetchResultDecodes() throws {
        let cards = try decode([AtprotoFetchedCard].self, """
            [{"uri": "at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/org.dotpostcard.postcard/3lbq2wcmaqs2a", "name": "eiffel-tower"}]
            """)
        XCTAssertEqual(cards, [AtprotoFetchedCard(uri: "at://did:plc:ewvi7nxzyoun6zhxrhs64oiz/org.dotpostcard.postcard/3lbq2wcmaqs2a", name: "eiffel-tower")])
    }

    func testCachePathIsKeyedByTheURIsOwnerAndRecordKey() {
        let url = AtmosphereCache.collectionURL(
            root: URL(fileURLWithPath: "/caches/Atmosphere"), uri: "at://did:plc:abc/org.dotpostcard.collection/3lbq2xxbkzk2c"
        )
        XCTAssertEqual(url?.path, "/caches/Atmosphere/did:plc:abc/3lbq2xxbkzk2c.postcards")
        XCTAssertEqual(url.map(AtmosphereCache.sidecarURL)?.path, "/caches/Atmosphere/did:plc:abc/3lbq2xxbkzk2c.json")
    }

    func testURIsThatCouldEscapeTheCacheAreRefused() {
        let root = URL(fileURLWithPath: "/caches/Atmosphere")
        XCTAssertNil(AtmosphereCache.collectionURL(root: root, uri: "at://did:plc:abc/org.dotpostcard.collection/.."))
        XCTAssertNil(AtmosphereCache.collectionURL(root: root, uri: "at://did:plc:abc/org.dotpostcard.collection/a%2Fb"))
        XCTAssertNil(AtmosphereCache.collectionURL(root: root, uri: "at://../org.dotpostcard.collection/3lbq2xxbkzk2c"))
        XCTAssertNil(AtmosphereCache.collectionURL(root: root, uri: "at://alice.example.com/org.dotpostcard.collection/3lbq2xxbkzk2c"), "a handle isn't a stable owner")
    }

    func testSidecarRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let collection = directory.appending(path: "3lbq2xxbkzk2c.postcards")
        let sidecar = AtprotoCollectionSidecar(cid: "bafyabc", cards: [AtprotoFetchedCard(uri: "at://did:plc:abc/org.dotpostcard.postcard/1", name: "one")])

        try AtmosphereCache.writeSidecar(sidecar, forCollectionAt: collection)

        XCTAssertEqual(AtmosphereCache.readSidecar(forCollectionAt: collection), sidecar)
    }

    func testRefetchesOnlyWhenTheRecordChanged() {
        let sidecar = AtprotoCollectionSidecar(cid: "bafyold", cards: [])
        XCTAssertFalse(AtmosphereCache.needsFetch(isCached: true, recordCID: "bafyold", sidecar: sidecar))
        XCTAssertTrue(AtmosphereCache.needsFetch(isCached: true, recordCID: "bafynew", sidecar: sidecar))
        XCTAssertTrue(AtmosphereCache.needsFetch(isCached: true, recordCID: "bafyold", sidecar: nil))
        XCTAssertTrue(AtmosphereCache.needsFetch(isCached: false, recordCID: "bafyold", sidecar: sidecar))
    }

    func testAtmosphereCollectionIsNeverAWriteDestination() {
        let source = LibrarySource.atprotoCollection(uri: "at://did:plc:abc/org.dotpostcard.collection/1", path: "/c/1.postcards", displayName: "Theirs")
        XCTAssertFalse(source.isWritable)
        XCTAssertTrue(WritableCollection.known(sources: [source], downloaded: []).isEmpty)
    }

    func testOnlyAFileWithItsRecordCIDStoredIsComplete() {
        XCTAssertTrue(AtmosphereCache.isComplete(sidecar: AtprotoCollectionSidecar(cid: "bafyabc", cards: [])))
        XCTAssertFalse(AtmosphereCache.isComplete(sidecar: nil))
        XCTAssertFalse(AtmosphereCache.isComplete(sidecar: AtprotoCollectionSidecar(cid: "", cards: [])))
    }

    func testAPartialDownloadOpensOnceItHoldsACard() {
        XCTAssertFalse(AtmosphereCache.isBrowsable(isComplete: false, cardCount: 0))
        XCTAssertTrue(AtmosphereCache.isBrowsable(isComplete: false, cardCount: 1))
        XCTAssertTrue(AtmosphereCache.isBrowsable(isComplete: true, cardCount: 0), "an empty collection is still a collection")
    }

    func testFetchProgress() {
        XCTAssertNil(CollectionFetchProgress().fraction, "spins until the first card says how many")
        XCTAssertNil(CollectionFetchProgress().remaining)
        let progress = CollectionFetchProgress(done: 178, total: 712)
        XCTAssertEqual(progress.fraction, 0.25)
        XCTAssertEqual(progress.remaining, 534)
        XCTAssertEqual(CollectionFetchProgress(done: 712, total: 712).remaining, 0)
    }

    func testReloadsAreThrottledWithOneAfterTheLastChange() throws {
        var throttle = ReloadThrottle(interval: 0.5)
        XCTAssertEqual(throttle.schedule(at: 10), 0, "the first card shows at once")
        throttle.didReload(at: 10)

        XCTAssertEqual(try XCTUnwrap(throttle.schedule(at: 10.1)), 0.4, accuracy: 0.001, "the next waits out the interval")
        XCTAssertNil(throttle.schedule(at: 10.2), "and later cards ride along with it")
        XCTAssertNil(throttle.schedule(at: 10.4))
        throttle.didReload(at: 10.5)

        XCTAssertEqual(throttle.schedule(at: 12), 0, "a slow card shows as soon as it lands")
    }
}
