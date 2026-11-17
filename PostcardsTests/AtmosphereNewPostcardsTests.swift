import XCTest

final class AtmosphereNewPostcardsTests: XCTestCase {
    private let collection = "at://did:plc:owner/org.dotpostcard.collection/3lbq2xxbkzk2c"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func downloaded(_ postcards: [String]) -> AtmosphereNewPostcards {
        var tracker = AtmosphereNewPostcards()
        tracker.downloaded(collection, postcards: postcards)
        return tracker
    }

    func testFirstDownloadKnowsEverything() {
        XCTAssertEqual(AtmosphereNewPostcards().unseen(in: collection, postcards: ["a"]), [], "Never downloaded: nothing to compare against")
        XCTAssertEqual(downloaded(["a", "b"]).unseen(in: collection, postcards: ["a", "b"]), [])
    }

    func testLaterRecordsExtraPostcardsAreUnseenAndRemovedOnesIgnored() {
        var tracker = downloaded(["a", "b"])
        XCTAssertEqual(tracker.unseen(in: collection, postcards: ["a", "c", "d"]), ["c", "d"])
        tracker.downloaded(collection, postcards: ["a", "c", "d"])
        XCTAssertEqual(tracker.unseen(in: collection, postcards: ["a", "c", "d"]), ["c", "d"], "Only the first download makes postcards known")
    }

    func testOpeningSeesThemAndTheyStayNewForTwelveHours() {
        var tracker = downloaded(["a"])
        let record = ["a", "b"]
        XCTAssertEqual(tracker.new(in: collection, at: t0), [], "Unseen isn't new yet")

        XCTAssertTrue(tracker.open(collection, postcards: record, at: t0))
        XCTAssertEqual(tracker.unseen(in: collection, postcards: record), [])
        XCTAssertEqual(tracker.new(in: collection, at: t0.addingTimeInterval(11 * 3600)), ["b"])
        XCTAssertEqual(tracker.new(in: collection, at: t0.addingTimeInterval(12 * 3600)), [])

        XCTAssertFalse(tracker.open(collection, postcards: record, at: t0.addingTimeInterval(60)), "Reopening doesn't restart the clock")
        XCTAssertEqual(tracker.new(in: collection, at: t0.addingTimeInterval(12 * 3600)), [])
    }

    func testANewProcessForgetsWhatWasNewButNotWhatWasSeen() throws {
        var tracker = downloaded(["a"])
        tracker.open(collection, postcards: ["a", "b"], at: t0)

        let relaunched = try JSONDecoder().decode(AtmosphereNewPostcards.self, from: JSONEncoder().encode(tracker))
        XCTAssertEqual(relaunched.new(in: collection, at: t0), [])
        XCTAssertEqual(relaunched.unseen(in: collection, postcards: ["a", "b"]), [])
        XCTAssertEqual(relaunched.unseen(in: collection, postcards: ["a", "b", "c"]), ["c"])
    }

    func testUnfollowedCollectionsStartAfresh() {
        var tracker = downloaded(["a"])
        XCTAssertTrue(tracker.keepOnly([]))
        XCTAssertEqual(tracker.unseen(in: collection, postcards: ["a", "b"]), [])
    }

    func testResultsNarrowToTheNewPostcardsCurrentNames() {
        let fetched = [AtprotoFetchedCard(uri: "a", name: "eiffel-tower"), AtprotoFetchedCard(uri: "b", name: "big-ben")]
        let names = AtmosphereNewPostcards.names(of: ["b", "not-downloaded"], in: fetched)
        XCTAssertEqual(names, ["big-ben"])
        XCTAssertEqual(AtmosphereNewPostcards.onlyNew([card("eiffel-tower"), card("big-ben")], names: names).map(\.name), ["big-ben"])
    }

    func testBackgroundRefetchOnlyForAnOutdatedCompleteCopyOffLowDataMode() {
        let current = AtprotoCollectionSidecar(cid: "old", cards: [])
        XCTAssertTrue(AtmosphereCache.refetchesInBackground(recordCID: "new", sidecar: current, isLowDataMode: false))
        XCTAssertFalse(AtmosphereCache.refetchesInBackground(recordCID: "new", sidecar: current, isLowDataMode: true))
        XCTAssertFalse(AtmosphereCache.refetchesInBackground(recordCID: "old", sidecar: current, isLowDataMode: false))
        XCTAssertFalse(AtmosphereCache.refetchesInBackground(recordCID: "new", sidecar: nil, isLowDataMode: false), "Never downloaded")
        XCTAssertFalse(AtmosphereCache.refetchesInBackground(recordCID: "new", sidecar: AtprotoCollectionSidecar(cid: "", cards: []), isLowDataMode: false), "Partial")
    }

    private func card(_ name: String) -> CardSummary {
        CardSummary(
            name: name, filename: "\(name).postcard.jpeg", mimetype: "image/jpeg", flip: .none, sentOn: nil,
            senderName: nil, recipientName: nil, locationName: nil, countryCode: nil, latitude: nil, longitude: nil,
            frontPxW: 100, frontPxH: 150, hasBack: false
        )
    }
}
