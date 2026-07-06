import CoreLocation
import XCTest

final class MapPinGroupingTests: XCTestCase {
    private struct Card {
        var name: String
        var coordinate: CLLocationCoordinate2D?
    }

    private let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
    private let kyoto = CLLocationCoordinate2D(latitude: 35.0116, longitude: 135.7681)

    func testEmptyInputHasNoGroups() {
        XCTAssertTrue(MapPinGrouping.groups(of: [Card](), coordinate: \.coordinate).isEmpty)
    }

    func testDistinctCoordinatesGetOnePinEach() {
        let groups = MapPinGrouping.groups(
            of: [Card(name: "a", coordinate: paris), Card(name: "b", coordinate: kyoto)],
            coordinate: \.coordinate
        )
        XCTAssertEqual(groups.map { $0.elements.map(\.name) }, [["a"], ["b"]])
    }

    func testExactlyCoLocatedCardsShareOnePin() {
        let groups = MapPinGrouping.groups(
            of: [
                Card(name: "a", coordinate: paris),
                Card(name: "b", coordinate: kyoto),
                Card(name: "c", coordinate: paris),
            ],
            coordinate: \.coordinate
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].elements.map(\.name), ["a", "c"], "co-located cards must join the first pin at their coordinate")
        XCTAssertEqual(groups[0].coordinate.latitude, paris.latitude)
        XCTAssertEqual(groups[1].elements.map(\.name), ["b"])
    }

    func testNearbyButNotIdenticalCoordinatesStaySeparate() {
        // Exact-equality grouping, not distance clustering: a hair apart is two pins.
        let nearParis = CLLocationCoordinate2D(latitude: paris.latitude + 0.000001, longitude: paris.longitude)
        let groups = MapPinGrouping.groups(
            of: [Card(name: "a", coordinate: paris), Card(name: "b", coordinate: nearParis)],
            coordinate: \.coordinate
        )
        XCTAssertEqual(groups.count, 2)
    }

    func testCardsWithoutCoordinatesAreDropped() {
        let groups = MapPinGrouping.groups(
            of: [Card(name: "a", coordinate: nil), Card(name: "b", coordinate: paris)],
            coordinate: \.coordinate
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].elements.map(\.name), ["b"])
    }

    func testGroupOrderFollowsFirstAppearance() {
        let groups = MapPinGrouping.groups(
            of: [
                Card(name: "a", coordinate: kyoto),
                Card(name: "b", coordinate: paris),
                Card(name: "c", coordinate: kyoto),
            ],
            coordinate: \.coordinate
        )
        XCTAssertEqual(groups.map(\.coordinate.latitude), [kyoto.latitude, paris.latitude])
    }
}
