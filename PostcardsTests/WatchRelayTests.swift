import XCTest

/// Covers the relay's pure wire types: what the phone plans to send for a watch request, the
/// request's own encoding, and the details built for the watch's info page.
final class WatchRelayTests: XCTestCase {
    private let cards = ["a", "b", "c", "d"]

    // MARK: - WatchStreamPlan

    func testAFreshRequestSendsTheFirstCardsAsMessagesAndQueuesTheRest() {
        let plan = WatchStreamPlan(cardNames: cards, request: .everything, immediateLimit: 2)

        XCTAssertEqual(plan.immediateScreenCards, ["a", "b"])
        XCTAssertEqual(plan.queuedScreenCards, ["c", "d"])
        XCTAssertTrue(plan.sendsDetails)
        XCTAssertEqual(plan.queuedZoomCards, cards)
    }

    func testAnUnreachableWatchGetsNothingAsMessages() {
        let plan = WatchStreamPlan(cardNames: cards, request: .everything, immediateLimit: 0)

        XCTAssertEqual(plan.immediateScreenCards, [])
        XCTAssertEqual(plan.queuedScreenCards, cards)
    }

    func testCardsTheWatchHasAreSkippedAndTheFirstMissingOnesGoFirst() {
        var request = WatchDownloadRequest()
        request.haveScreen = ["a", "c"]
        request.haveZoom = ["a"]
        request.haveDetails = true

        let plan = WatchStreamPlan(cardNames: cards, request: request, immediateLimit: 1)

        XCTAssertEqual(plan.immediateScreenCards, ["b"])
        XCTAssertEqual(plan.queuedScreenCards, ["d"])
        XCTAssertFalse(plan.sendsDetails)
        XCTAssertEqual(plan.queuedZoomCards, ["b", "c", "d"])
    }

    func testAnUnpinnedRequestQueuesNoZoomFaces() {
        var request = WatchDownloadRequest()
        request.wantsZoom = false

        XCTAssertEqual(WatchStreamPlan(cardNames: cards, request: request, immediateLimit: 2).queuedZoomCards, [])
    }

    func testTheImmediateLimitNeverExceedsWhatsMissing() {
        var request = WatchDownloadRequest()
        request.haveScreen = ["a", "b", "c"]

        let plan = WatchStreamPlan(cardNames: cards, request: request, immediateLimit: 5)

        XCTAssertEqual(plan.immediateScreenCards, ["d"])
        XCTAssertEqual(plan.queuedScreenCards, [])
    }

    func testARequestRoundTripsThroughJSON() throws {
        var request = WatchDownloadRequest()
        request.haveScreen = ["Front & Back", "Kyoto"]
        request.haveZoom = ["Kyoto"]
        request.haveDetails = true
        request.wantsZoom = false

        let decoded = try JSONDecoder().decode(WatchDownloadRequest.self, from: JSONEncoder().encode(request))

        XCTAssertEqual(decoded, request)
    }

    // MARK: - WatchCardDetails

    private func summary(
        name: String = "Kyoto",
        senderName: String? = nil,
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> CardSummary {
        CardSummary(
            name: name, filename: "\(name).postcard.webp", mimetype: "image/webp", flip: .book,
            sentOn: nil, senderName: senderName, recipientName: nil, locationName: locationName,
            countryCode: nil, latitude: latitude, longitude: longitude,
            frontPxW: 300, frontPxH: 200, hasBack: true
        )
    }

    private func metadata(_ json: String) throws -> PostcardMetadata {
        try JSONDecoder().decode(PostcardMetadata.self, from: Data(json.utf8))
    }

    func testDetailsFromASummaryAloneKeepWhatItCarries() {
        let details = WatchCardDetails(
            summary: summary(senderName: "Claire", locationName: "Kyoto", latitude: 35.0, longitude: 135.8),
            metadata: nil
        )

        XCTAssertEqual(details.name, "Kyoto")
        XCTAssertEqual(details.senderName, "Claire")
        XCTAssertEqual(details.locationName, "Kyoto")
        XCTAssertEqual(details.latitude, 35.0)
        XCTAssertEqual(details.longitude, 135.8)
        XCTAssertNil(details.backTranscription)
    }

    func testDetailsPreferTheFullMetadataAndFlattenItsTexts() throws {
        let full = try metadata("""
        {
          "location": {"name": "Kyoto, Japan", "latitude": 35.01, "longitude": 135.77, "countrycode": "JPN"},
          "flip": "book",
          "sentOn": "2024-04-02",
          "sender": {"name": "Claire"},
          "recipient": {"name": "JP"},
          "front": {"description": "A temple in blossom"},
          "back": {"transcription": {"text": "Wish you were here!", "annotations": [{"type": "em", "start": 0, "end": 4}]}},
          "context": {"author": {"name": "JP"}, "description": "From the Kyoto trip"}
        }
        """)

        let details = WatchCardDetails(summary: summary(senderName: "C."), metadata: full)

        XCTAssertEqual(details.senderName, "Claire")
        XCTAssertEqual(details.recipientName, "JP")
        XCTAssertEqual(details.locationName, "Kyoto, Japan")
        XCTAssertEqual(details.countryCode, "JPN")
        XCTAssertEqual(details.latitude, 35.01)
        XCTAssertEqual(details.sentOn, full.sentOn)
        XCTAssertEqual(details.frontDescription, "A temple in blossom")
        XCTAssertEqual(details.backTranscription, "Wish you were here!")
        XCTAssertNil(details.frontTranscription)
        XCTAssertEqual(details.collectorName, "JP")
        XCTAssertEqual(details.notes, "From the Kyoto trip")
    }

    func testBlankTextsBecomeNil() throws {
        let full = try metadata("""
        {"sender": {"name": "  "}, "front": {"description": ""}, "back": {"transcription": {"text": "\\n"}}}
        """)

        let details = WatchCardDetails(summary: summary(), metadata: full)

        XCTAssertNil(details.senderName)
        XCTAssertNil(details.frontDescription)
        XCTAssertNil(details.backTranscription)
    }

    func testHalfACoordinateIsNoCoordinateAtAll() {
        let details = WatchCardDetails(summary: summary(latitude: 35.0), metadata: nil)

        XCTAssertNil(details.latitude)
        XCTAssertNil(details.longitude)
        XCTAssertFalse(LocationDisplay.hasCoordinates(details.location))
    }

    func testDetailsRoundTripThroughJSON() throws {
        let details = WatchCardDetails(summary: summary(senderName: "Claire", locationName: "Kyoto"), metadata: nil)

        let decoded = try JSONDecoder().decode([WatchCardDetails].self, from: JSONEncoder().encode([details]))

        XCTAssertEqual(decoded, [details])
    }
}
