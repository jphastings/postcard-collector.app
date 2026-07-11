import CoreLocation
import XCTest

final class MapClusterZoomTests: XCTestCase {
    func testIdenticalCoordinatesAlwaysCycle() {
        let point = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        guard case .cycle = MapClusterZoom.decision(for: [point, point, point]) else {
            return XCTFail("a stack on one exact point can never disaggregate, so it must cycle")
        }
    }

    func testTightlyPackedMembersCycle() {
        // ~300m apart — even a close-in camera wouldn't usefully separate these.
        let a = CLLocationCoordinate2D(latitude: 51.500, longitude: -0.120)
        let b = CLLocationCoordinate2D(latitude: 51.503, longitude: -0.120)
        guard case .cycle = MapClusterZoom.decision(for: [a, b]) else {
            return XCTFail("members under the minimum useful span should cycle, not zoom")
        }
    }

    func testSpreadMembersZoomToARegionContainingThemAll() {
        // ~50km apart — comfortably separable.
        let a = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        let b = CLLocationCoordinate2D(latitude: 51.9, longitude: -0.60)
        guard case .zoom(let region) = MapClusterZoom.decision(for: [a, b]) else {
            return XCTFail("well-separated members should zoom to disaggregate")
        }
        for member in [a, b] {
            XCTAssertLessThanOrEqual(abs(member.latitude - region.center.latitude), region.span.latitudeDelta / 2)
            XCTAssertLessThanOrEqual(abs(member.longitude - region.center.longitude), region.span.longitudeDelta / 2)
        }
    }
}
