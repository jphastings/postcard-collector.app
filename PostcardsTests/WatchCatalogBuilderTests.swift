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

    func testItemWithNoReaderFallsBackToDisplayNameWithNoCards() {
        let item = CloudItem(path: "/cloud/trip.postcards", displayName: "trip", isCollection: true, downloadState: .remote)

        let entry = WatchCatalogBuilder.entry(for: item, reader: nil)

        XCTAssertEqual(entry.id, "trip")
        XCTAssertEqual(entry.title, "trip")
        XCTAssertEqual(entry.cardCount, 0)
    }

    func testItemWithAReaderUsesItsTitleAndCount() throws {
        let path = try fixturePath()
        let readerForExpectations = try CollectionReader(path: path)
        let expectedSummaries = try readerForExpectations.cardSummaries()
        let expectedTitle = try XCTUnwrap(readerForExpectations.title())

        let item = CloudItem(path: path, displayName: "trip", isCollection: true, downloadState: .current)
        let entry = WatchCatalogBuilder.entry(for: item, reader: try CollectionReader(path: path))

        XCTAssertEqual(entry.id, "trip", "id always keys off displayName, never the reader's title")
        XCTAssertEqual(entry.title, expectedTitle)
        XCTAssertEqual(entry.cardCount, expectedSummaries.count)
    }

    // MARK: - Atmosphere

    private let alice = "did:plc:alice"
    private let carol = "did:plc:carol"
    private let alicesTrip = "at://did:plc:alice/org.dotpostcard.collection/trip"
    private let alicesUndownloaded = "at://did:plc:alice/org.dotpostcard.collection/later"
    private let bobsPartial = "at://did:plc:bob/org.dotpostcard.collection/rome"
    private let bobsEmpty = "at://did:plc:bob/org.dotpostcard.collection/empty"

    private func record(_ uri: String, _ title: String) -> AtprotoCollection {
        AtprotoCollection(uri: uri, cid: "cid", title: title, cardCount: 99, createdAt: "", postcards: [])
    }

    private func follow(_ subject: String) -> AtprotoFollow {
        AtprotoFollow(uri: "at://\(carol)/org.dotpostcard.follow/\(subject.count)", subject: subject, createdAt: "")
    }

    /// Alice owns a downloaded collection (which Carol also follows) and an undownloaded one;
    /// Carol follows one of Bob's, partly downloaded, and another whose file holds no cards yet.
    private func atmosphereRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([record(alicesTrip, "Alice's trip"), record(alicesUndownloaded, "Later")])
            .write(to: AtmosphereCache.listingURL(root: root, did: alice))
        let following = AtmosphereFollowingSnapshot(
            follows: [carol: [follow(alicesTrip), follow(bobsPartial), follow(bobsEmpty)]],
            records: [bobsPartial: record(bobsPartial, "Bob's Rome"), bobsEmpty: record(bobsEmpty, "Empty")]
        )
        try JSONEncoder().encode(following).write(to: AtmosphereCache.followingURL(root: root))

        for uri in [alicesTrip, bobsPartial] {
            let url = try XCTUnwrap(AtmosphereCache.collectionURL(root: root, uri: uri))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: fixturePath(), toPath: url.path)
        }
        try AtmosphereCache.writeSidecar(
            AtprotoCollectionSidecar(cid: "cid", cards: []), forCollectionAt: XCTUnwrap(AtmosphereCache.collectionURL(root: root, uri: alicesTrip))
        )
        let empty = try XCTUnwrap(AtmosphereCache.collectionURL(root: root, uri: bobsEmpty))
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        return root
    }

    func testTheCatalogListsICloudAndDownloadedAtmosphereCollectionsOnceEach() throws {
        let fixtureCount = try CollectionReader(path: fixturePath()).cardCount()
        let item = CloudItem(path: "/cloud/Alice's trip.postcards", displayName: "Alice's trip", isCollection: true, downloadState: .remote)

        let atmosphere = AtmosphereCache.downloadedCollections(root: try atmosphereRoot())
        let catalog = [WatchCatalogBuilder.entry(for: item, reader: nil)] + atmosphere.map(WatchCatalogBuilder.entry(for:))

        XCTAssertEqual(catalog.map(\.title), ["Alice's trip", "Alice's trip", "Bob's Rome"])
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count, "ids never clash, even with an identically named iCloud file")
        XCTAssertEqual(catalog.map(\.atmosphere), [nil, .own, .followed], "owned and followed counts as own")
        XCTAssertEqual(catalog.dropFirst().map(\.cardCount), [fixtureCount, fixtureCount], "a partial download offers the cards in its file")
    }

    func testARequestResolvesToTheFileItsIDNames() throws {
        let item = CloudItem(path: "/cloud/Rome.postcards", displayName: "Rome", isCollection: true, downloadState: .current)
        let atmosphere = AtmosphereCache.downloadedCollections(root: try atmosphereRoot())
        let rome = try XCTUnwrap(atmosphere.first { $0.uri == bobsPartial })

        func path(_ id: String) -> String? {
            WatchCatalogBuilder.path(forID: id, cloudItems: [item], atmosphere: atmosphere)
        }

        XCTAssertEqual(path("Rome"), "/cloud/Rome.postcards")
        XCTAssertEqual(path(WatchCatalogBuilder.atmosphereID(uri: bobsPartial)), rome.path)
        XCTAssertNil(path(WatchCatalogBuilder.atmosphereID(uri: alicesUndownloaded)))
    }

    func testAtmosphereIDsAreStableSinglePathComponents() {
        let id = WatchCatalogBuilder.atmosphereID(uri: alicesTrip)

        XCTAssertEqual(id, WatchCatalogBuilder.atmosphereID(uri: alicesTrip))
        XCTAssertNotEqual(id, WatchCatalogBuilder.atmosphereID(uri: bobsPartial))
        XCTAssertFalse(id.contains("/"))
    }
}
