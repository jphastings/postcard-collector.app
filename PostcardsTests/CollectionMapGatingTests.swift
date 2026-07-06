import XCTest

final class CollectionMapGatingTests: XCTestCase {
    private func makeCard(name: String, latitude: Double? = nil, longitude: Double? = nil) -> CardSummary {
        CardSummary(
            name: name,
            filename: "\(name).postcard.jpeg",
            mimetype: "image/jpeg",
            flip: .none,
            sentOn: nil,
            senderName: nil,
            recipientName: nil,
            locationName: nil,
            countryCode: nil,
            latitude: latitude,
            longitude: longitude,
            frontPxW: 100,
            frontPxH: 150,
            hasBack: false
        )
    }

    // MARK: - isEnabled

    func testEmptyCollectionIsDisabled() {
        XCTAssertFalse(CollectionMapGating.isEnabled(for: []))
    }

    func testCollectionWithNoLocatedCardsIsDisabled() {
        let cards = [makeCard(name: "a"), makeCard(name: "b")]
        XCTAssertFalse(CollectionMapGating.isEnabled(for: cards))
    }

    func testCollectionWithOneLocatedCardIsEnabled() {
        let cards = [makeCard(name: "a"), makeCard(name: "b", latitude: 1, longitude: 2)]
        XCTAssertTrue(CollectionMapGating.isEnabled(for: cards))
    }

    func testCardWithOnlyLatitudeDoesNotCount() {
        let cards = [makeCard(name: "a", latitude: 1, longitude: nil)]
        XCTAssertFalse(CollectionMapGating.isEnabled(for: cards))
    }

    // MARK: - coordinates(in:)

    func testCoordinatesExtractsOnlyLocatedCards() {
        let cards = [
            makeCard(name: "a"),
            makeCard(name: "b", latitude: 10, longitude: 20),
            makeCard(name: "c", latitude: 30, longitude: 40),
        ]
        let coordinates = CollectionMapGating.coordinates(in: cards)

        XCTAssertEqual(coordinates.count, 2)
        XCTAssertEqual(coordinates[0].latitude, 10)
        XCTAssertEqual(coordinates[0].longitude, 20)
        XCTAssertEqual(coordinates[1].latitude, 30)
        XCTAssertEqual(coordinates[1].longitude, 40)
    }

    // MARK: - CardSummary.coordinate

    func testCardSummaryCoordinateRequiresBothFields() {
        XCTAssertNil(makeCard(name: "a").coordinate)
        XCTAssertNil(makeCard(name: "a", latitude: 1).coordinate)
        XCTAssertNil(makeCard(name: "a", longitude: 2).coordinate)
        XCTAssertNotNil(makeCard(name: "a", latitude: 1, longitude: 2).coordinate)
    }
}
