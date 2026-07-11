import CoreLocation
import XCTest

final class MapClusterZoomTests: XCTestCase {
    func testIdenticalCoordinatesAlwaysCycle() {
        let point = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        guard case .cycle = MapClusterZoom.decision(for: [point, point, point], centeredOn: point) else {
            return XCTFail("a stack on one exact point can never disaggregate, so it must cycle")
        }
    }

    func testTightlyPackedMembersCycle() {
        // ~300m apart — even a close-in camera wouldn't usefully separate these.
        let a = CLLocationCoordinate2D(latitude: 51.500, longitude: -0.120)
        let b = CLLocationCoordinate2D(latitude: 51.503, longitude: -0.120)
        let centroid = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: a.longitude)
        guard case .cycle = MapClusterZoom.decision(for: [a, b], centeredOn: centroid) else {
            return XCTFail("members under the minimum useful span should cycle, not zoom")
        }
    }

    func testSpreadMembersZoomToARegionContainingThemAll() {
        // ~50km apart — comfortably separable.
        let a = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        let b = CLLocationCoordinate2D(latitude: 51.9, longitude: -0.60)
        let centroid = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        guard case .zoom(let region) = MapClusterZoom.decision(for: [a, b], centeredOn: centroid) else {
            return XCTFail("well-separated members should zoom to disaggregate")
        }
        for member in [a, b] {
            XCTAssertLessThanOrEqual(abs(member.latitude - region.center.latitude), region.span.latitudeDelta / 2)
            XCTAssertLessThanOrEqual(abs(member.longitude - region.center.longitude), region.span.longitudeDelta / 2)
        }
    }

    func testZoomAlwaysRecentresOnTheGivenPinCoordinateNotTheMembersBoundingBox() {
        // The pin's displayed coordinate (its cluster's centroid) deliberately sits off to
        // one side of the members' own bounding box — simulating a cluster whose centroid
        // has drifted from a tight member spread. The camera must still land exactly on
        // the pin, not on the members' box centre, while still containing every member.
        let a = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        let b = CLLocationCoordinate2D(latitude: 51.9, longitude: -0.60)
        let pinCoordinate = CLLocationCoordinate2D(latitude: 51.6, longitude: -0.2)

        guard case .zoom(let region) = MapClusterZoom.decision(for: [a, b], centeredOn: pinCoordinate) else {
            return XCTFail("well-separated members should zoom to disaggregate")
        }

        XCTAssertEqual(region.center.latitude, pinCoordinate.latitude, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, pinCoordinate.longitude, accuracy: 1e-9)
        for member in [a, b] {
            XCTAssertLessThanOrEqual(abs(member.latitude - region.center.latitude), region.span.latitudeDelta / 2)
            XCTAssertLessThanOrEqual(abs(member.longitude - region.center.longitude), region.span.longitudeDelta / 2)
        }
    }
}
