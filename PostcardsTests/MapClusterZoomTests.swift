import CoreLocation
import MapKit
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

    func testThreeMemberClusterWithTwoSharingACoordinateAndOneFarAwayStillZooms() {
        // Transitive screen-space clustering (see `MapPinClustering`) can merge a pair at
        // one exact address with a third member from a genuinely distant one — the third
        // member alone is well past the useful-span threshold, so this must zoom, not
        // cycle, regardless of the other two sharing a coordinate.
        let sharedAddress = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12)
        let farAway = CLLocationCoordinate2D(latitude: 51.68, longitude: -0.12) // ~20km north
        let centroid = MapPinClustering.centroid(of: [sharedAddress, sharedAddress, farAway])!

        guard case .zoom = MapClusterZoom.decision(for: [sharedAddress, sharedAddress, farAway], centeredOn: centroid) else {
            return XCTFail("a genuinely 20km-distant member must zoom even when its cluster-mates share a coordinate")
        }
    }

    func testFiveSpreadMembersZoomToARegionContainingThemAll() {
        let members = [
            CLLocationCoordinate2D(latitude: 51.50, longitude: -0.10),
            CLLocationCoordinate2D(latitude: 51.52, longitude: -0.14),
            CLLocationCoordinate2D(latitude: 51.55, longitude: -0.08),
            CLLocationCoordinate2D(latitude: 51.60, longitude: -0.20),
            CLLocationCoordinate2D(latitude: 51.65, longitude: -0.30),
        ]
        let centroid = MapPinClustering.centroid(of: members)!

        guard case .zoom(let region) = MapClusterZoom.decision(for: members, centeredOn: centroid) else {
            return XCTFail("well-separated members should zoom to disaggregate")
        }
        for member in members {
            XCTAssertLessThanOrEqual(abs(member.latitude - region.center.latitude), region.span.latitudeDelta / 2)
            XCTAssertLessThanOrEqual(abs(member.longitude - region.center.longitude), region.span.longitudeDelta / 2)
        }
    }

    /// The screen separation the given region would put between the closest DISTINCT pair
    /// of `coordinates`, assuming a pane exactly `MapClusterZoom.assumedMinimumPaneSidePoints`
    /// across — mirrors the projection MapKit itself performs (one points-per-metre scale
    /// shared by both axes, bound by whichever axis needs more zoom-out to fit), so this
    /// answers the actual question a settle's reclustering asks: would these members end up
    /// far enough apart on screen to stay split apart, or would they immediately re-merge?
    private func predictedClosestPairSeparation(in coordinates: [CLLocationCoordinate2D], region: MKCoordinateRegion) -> CGFloat {
        var closest: CLLocationDistance?
        for i in coordinates.indices {
            for j in (i + 1)..<coordinates.count {
                let a = coordinates[i], b = coordinates[j]
                guard a.latitude != b.latitude || a.longitude != b.longitude else { continue }
                let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                closest = min(closest ?? distance, distance)
            }
        }
        guard let closest else { return .infinity }

        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = 111_320.0 * cos(region.center.latitude * .pi / 180)
        let regionWidthMeters = region.span.longitudeDelta * metersPerDegreeLongitude
        let regionHeightMeters = region.span.latitudeDelta * metersPerDegreeLatitude
        let bindingAxisMeters = max(regionWidthMeters, regionHeightMeters)
        return closest / bindingAxisMeters * MapClusterZoom.assumedMinimumPaneSidePoints
    }

    func testFourTightlyClusteredMembersPlusOneOutlierStillSeparateTheTightGroup() {
        // Four postcards from the same small neighbourhood (within 150m of each other) sit
        // in one screen-space cluster with a fifth, genuinely distant postcard 6km away.
        // The bounding-box-only sizing this used to use pads out to cover the 6km outlier
        // and, at that scale, the 150m-wide neighbourhood group stays fused together after
        // the "zoom" — the tap visibly does nothing to it. The region must instead be
        // tight enough that the neighbourhood group's own members clear the reclustering
        // threshold, even if that means the outlier ends up outside the immediate frame
        // (it still reappears as its own pin once the next settle reclusters).
        let neighbourhood = [
            CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1178352),
            CLLocationCoordinate2D(latitude: 51.5013475, longitude: -0.12),
            CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1221648),
            CLLocationCoordinate2D(latitude: 51.4986525, longitude: -0.12),
        ]
        let outlier = CLLocationCoordinate2D(latitude: 51.5539, longitude: -0.12) // ~6km north
        let members = neighbourhood + [outlier]
        let centroid = MapPinClustering.centroid(of: members)!

        guard case .zoom(let region) = MapClusterZoom.decision(for: members, centeredOn: centroid) else {
            return XCTFail("a 6km-distant member should still trigger a zoom")
        }

        let predicted = predictedClosestPairSeparation(in: members, region: region)
        XCTAssertGreaterThan(
            predicted, MapPinClustering.defaultThresholdPoints,
            "the tight neighbourhood group must clear the reclustering threshold, not stay fused after the zoom"
        )
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
