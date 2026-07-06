import CoreLocation
import MapKit
import XCTest

final class MapRegionFittingTests: XCTestCase {
    func testEmptyCoordinatesHaveNoRegion() {
        XCTAssertNil(MapRegionFitting.region(for: []))
    }

    func testSingleCoordinateGetsASaneNonZeroSpan() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let region = try XCTUnwrap(MapRegionFitting.region(for: [coordinate]))

        XCTAssertEqual(region.center.latitude, coordinate.latitude, accuracy: 0.0001)
        XCTAssertEqual(region.center.longitude, coordinate.longitude, accuracy: 0.0001)
        XCTAssertGreaterThan(region.span.latitudeDelta, 0)
        XCTAssertGreaterThan(region.span.longitudeDelta, 0)
    }

    func testIdenticalCoordinatesBehaveLikeASingleCoordinate() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 10, longitude: 20)
        let region = try XCTUnwrap(MapRegionFitting.region(for: [coordinate, coordinate, coordinate]))

        XCTAssertEqual(region.span.latitudeDelta, MapRegionFitting.minimumSpanDegrees, accuracy: 0.0001)
        XCTAssertEqual(region.span.longitudeDelta, MapRegionFitting.minimumSpanDegrees, accuracy: 0.0001)
    }

    func testRegionContainsEveryCoordinateWithPadding() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 35.0116, longitude: 135.7681), // Kyoto
            CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522), // Paris
            CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405), // Berlin
        ]
        let region = try XCTUnwrap(MapRegionFitting.region(for: coordinates))

        for coordinate in coordinates {
            XCTAssertLessThanOrEqual(
                abs(coordinate.latitude - region.center.latitude),
                region.span.latitudeDelta / 2,
                "\(coordinate) falls outside the fitted region's latitude span"
            )
            XCTAssertLessThanOrEqual(
                abs(coordinate.longitude - region.center.longitude),
                region.span.longitudeDelta / 2,
                "\(coordinate) falls outside the fitted region's longitude span"
            )
        }

        // Padding must make the span strictly larger than the tight bounding box, so pins
        // don't sit flush against the map's edge.
        let tightLatitudeSpan = 52.52 - 35.0116
        let tightLongitudeSpan = 135.7681 - 2.3522
        XCTAssertGreaterThan(region.span.latitudeDelta, tightLatitudeSpan)
        XCTAssertGreaterThan(region.span.longitudeDelta, tightLongitudeSpan)
    }

    func testCenterIsTheMidpointOfTheBoundingBox() throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 10, longitude: 20),
        ]
        let region = try XCTUnwrap(MapRegionFitting.region(for: coordinates))

        XCTAssertEqual(region.center.latitude, 5, accuracy: 0.0001)
        XCTAssertEqual(region.center.longitude, 10, accuracy: 0.0001)
    }
}
