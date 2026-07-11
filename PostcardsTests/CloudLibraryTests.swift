import XCTest

/// Covers `CloudLibrary`'s pure logic — filename classification, download-state mapping,
/// content-change detection, and the `NSMetadataQuery` predicate — without touching a real
/// ubiquity container or `NSMetadataQuery` itself (neither is fakeable in a unit test).
final class CloudLibraryTests: XCTestCase {
    // MARK: - Filename classification

    func testCollectionFilenamesAreClassifiedByExtension() {
        XCTAssertEqual(CloudItemAttributes.kind(forFilename: "Trip to Kyoto.postcards"), .collection)
        XCTAssertEqual(CloudItemAttributes.kind(forFilename: "TRIP.POSTCARDS"), .collection, "classification must be case-insensitive")
    }

    func testBareCardFilenamesAreClassifiedRegardlessOfImageType() {
        for ext in ["webp", "jpg", "jpeg", "png"] {
            XCTAssertEqual(CloudItemAttributes.kind(forFilename: "righthand-card.postcard.\(ext)"), .card)
        }
    }

    func testUnrelatedFilenamesAreNeitherCollectionNorCard() {
        XCTAssertEqual(CloudItemAttributes.kind(forFilename: "notes.txt"), .other)
        XCTAssertEqual(CloudItemAttributes.kind(forFilename: "postcards"), .other, "no extension, just the bare word")
    }

    func testSingleExtensionFileIsClassifiedByKind() {
        XCTAssertEqual(CloudItemAttributes.kind(forFilename: "foo.postcard"), .card)
        XCTAssertEqual(CloudItemAttributes.kind(forFilename: "foo.postcards"), .collection)
    }

    func testBareCardSuffixStillClassifiesCompoundCardFilesAsCards() {
        XCTAssertEqual(CloudItemAttributes.kind(forFilename: "foo.postcard.webp"), .card)
    }

    // MARK: - Display names

    func testDisplayNameStripsTheCollectionSuffix() {
        XCTAssertEqual(CloudItemAttributes.displayName(forFilename: "Trip to Kyoto.postcards"), "Trip to Kyoto")
    }

    func testDisplayNameStripsTheFullCompoundCardSuffix() {
        XCTAssertEqual(CloudItemAttributes.displayName(forFilename: "righthand-card.postcard.jpeg"), "righthand-card")
    }

    func testDisplayNameStripsTheBareCardSuffix() {
        XCTAssertEqual(CloudItemAttributes.displayName(forFilename: "foo.postcard"), "foo")
    }

    func testDisplayNameStripsTheCompoundCardSuffixToo() {
        XCTAssertEqual(CloudItemAttributes.displayName(forFilename: "foo.postcard.webp"), "foo")
    }

    // MARK: - Download state

    func testCurrentStatusMapsToCurrentRegardlessOfPercent() {
        XCTAssertEqual(
            CloudItemAttributes.downloadState(status: NSMetadataUbiquitousItemDownloadingStatusCurrent, percentDownloaded: nil),
            .current
        )
    }

    func testInFlightPercentMapsToDownloading() {
        XCTAssertEqual(
            CloudItemAttributes.downloadState(status: NSMetadataUbiquitousItemDownloadingStatusNotDownloaded, percentDownloaded: 42),
            .downloading(percent: 42)
        )
    }

    func testNoProgressYetMapsToRemote() {
        XCTAssertEqual(
            CloudItemAttributes.downloadState(status: NSMetadataUbiquitousItemDownloadingStatusNotDownloaded, percentDownloaded: nil),
            .remote
        )
        XCTAssertEqual(
            CloudItemAttributes.downloadState(status: nil, percentDownloaded: 0),
            .remote
        )
        XCTAssertEqual(
            CloudItemAttributes.downloadState(status: nil, percentDownloaded: 100),
            .remote,
            "100% still isn't \"current\" until the status attribute confirms it"
        )
    }

    // MARK: - Content-change detection (drives the invalidate-and-reopen path)

    func testFirstSightingIsNeverAChange() {
        XCTAssertFalse(CloudItemAttributes.hasContentChanged(previousChangeDate: nil, currentChangeDate: Date()))
    }

    func testLaterContentChangeDateIsAChange() {
        let earlier = Date(timeIntervalSince1970: 1000)
        let later = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(CloudItemAttributes.hasContentChanged(previousChangeDate: earlier, currentChangeDate: later))
        XCTAssertFalse(CloudItemAttributes.hasContentChanged(previousChangeDate: later, currentChangeDate: earlier))
        XCTAssertFalse(CloudItemAttributes.hasContentChanged(previousChangeDate: earlier, currentChangeDate: earlier))
    }

    func testMissingCurrentDateIsNeverAChange() {
        XCTAssertFalse(CloudItemAttributes.hasContentChanged(previousChangeDate: Date(), currentChangeDate: nil))
    }

    // MARK: - NSMetadataQuery predicate

    func testPredicateMatchesCollectionsAndBareCardFiles() {
        let predicate = CloudLibrary.metadataQueryPredicate()

        XCTAssertTrue(predicate.evaluate(with: [NSMetadataItemFSNameKey: "Trip to Kyoto.postcards"]))
        XCTAssertTrue(predicate.evaluate(with: [NSMetadataItemFSNameKey: "righthand-card.postcard.webp"]))
        XCTAssertTrue(predicate.evaluate(with: [NSMetadataItemFSNameKey: "righthand-card.postcard"]), "bare .postcard files must match too")
        XCTAssertFalse(predicate.evaluate(with: [NSMetadataItemFSNameKey: "notes.txt"]))
        XCTAssertFalse(predicate.evaluate(with: [NSMetadataItemFSNameKey: "vacation.jpeg"]))
    }

    // MARK: - CloudItem -> LibrarySource

    func testLibrarySourceReflectsTheItemsKind() {
        let collection = CloudItem(path: "/cloud/trip.postcards", displayName: "trip", isCollection: true, downloadState: .current)
        XCTAssertEqual(collection.librarySource, .collection(path: "/cloud/trip.postcards", displayName: "trip"))

        let card = CloudItem(path: "/cloud/card.postcard.webp", displayName: "card", isCollection: false, downloadState: .current)
        XCTAssertEqual(card.librarySource, .cardFile(path: "/cloud/card.postcard.webp", displayName: "card"))
    }

    // MARK: - CardReference from a cross-source LibraryHit

    func testCardReferenceClassifiesHitsFromCollectionsAndBareFilesBySourceExtension() throws {
        let json = """
        [
            {"source":"/cloud/trip.postcards","card":{"name":"a","filename":"a.postcard.jpeg","mimetype":"image/jpeg","flip":"book","front_px_w":1,"front_px_h":1,"has_back":false},"snippet":"a"},
            {"source":"/cloud/loose.postcard.webp","card":{"name":"b","filename":"b.postcard.webp","mimetype":"image/webp","flip":"none","front_px_w":1,"front_px_h":1,"has_back":false},"snippet":"b"}
        ]
        """
        let hits = try JSONDecoder().decode([LibraryHit].self, from: Data(json.utf8))
        XCTAssertEqual(hits.count, 2)

        guard case .inCollection(let path, let summary) = CardReference(hit: hits[0]) else {
            return XCTFail("expected an in-collection reference")
        }
        XCTAssertEqual(path, "/cloud/trip.postcards")
        XCTAssertEqual(summary.name, "a")

        guard case .bareFile(let barePath, let bareSummary) = CardReference(hit: hits[1]) else {
            return XCTFail("expected a bare-file reference")
        }
        XCTAssertEqual(barePath, "/cloud/loose.postcard.webp")
        XCTAssertEqual(bareSummary.name, "b")
    }

    // MARK: - shouldAutoDownload default

    /// iOS/macOS rely on `shouldAutoDownload`'s default (download everything) being
    /// unchanged by the watch app's pin-aware override — see `PostcardsApp`, which never
    /// sets this closure itself.
    @MainActor
    func testShouldAutoDownloadDefaultsToTrueForAnyItem() {
        let cloudLibrary = CloudLibrary()
        let item = CloudItem(path: "/cloud/trip.postcards", displayName: "trip", isCollection: true, downloadState: .remote)
        XCTAssertTrue(cloudLibrary.shouldAutoDownload(item))
    }

    // MARK: - start() idempotency

    /// `WatchConnectivityProvider` and `PostcardsApp`'s `.task` can both end up kicking
    /// `start()` (the provider does so whenever a watch request arrives before the library is
    /// ready) — a second call must be a harmless no-op rather than re-resolving the container
    /// or restarting the query.
    @MainActor
    func testStartCalledTwiceIsIdempotent() async {
        let cloudLibrary = CloudLibrary()
        await cloudLibrary.start()
        let stateAfterFirstStart = cloudLibrary.containerState

        await cloudLibrary.start()

        XCTAssertEqual(cloudLibrary.containerState, stateAfterFirstStart)
    }
}
