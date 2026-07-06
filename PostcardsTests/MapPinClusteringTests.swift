import CoreLocation
import XCTest

final class MapPinClusteringTests: XCTestCase {
    private struct Pin: Equatable {
        var name: String
        var point: CGPoint?
    }

    private func clusters(_ pins: [Pin], threshold: CGFloat = MapPinClustering.defaultThresholdPoints) -> [[String]] {
        MapPinClustering.clusters(of: pins, threshold: threshold) { $0.point }
            .map { $0.map(\.name) }
    }

    func testFarApartPinsStaySeparate() {
        let result = clusters([
            Pin(name: "a", point: CGPoint(x: 0, y: 0)),
            Pin(name: "b", point: CGPoint(x: 200, y: 0)),
        ])
        XCTAssertEqual(result, [["a"], ["b"]])
    }

    func testOverlappingPinsMerge() {
        let result = clusters([
            Pin(name: "a", point: CGPoint(x: 0, y: 0)),
            Pin(name: "b", point: CGPoint(x: 10, y: 10)),
        ])
        XCTAssertEqual(result, [["a", "b"]])
    }

    func testExactCoordinateDuplicatesAlwaysMerge() {
        let point = CGPoint(x: 50, y: 50)
        let result = clusters([Pin(name: "a", point: point), Pin(name: "b", point: point)])
        XCTAssertEqual(result, [["a", "b"]])
    }

    func testThresholdBoundaryIsInclusive() {
        let atThreshold = clusters([
            Pin(name: "a", point: CGPoint(x: 0, y: 0)),
            Pin(name: "b", point: CGPoint(x: 44, y: 0)),
        ])
        XCTAssertEqual(atThreshold, [["a", "b"]], "exactly threshold apart must still merge")

        let justBeyond = clusters([
            Pin(name: "a", point: CGPoint(x: 0, y: 0)),
            Pin(name: "b", point: CGPoint(x: 44.5, y: 0)),
        ])
        XCTAssertEqual(justBeyond, [["a"], ["b"]])
    }

    func testChainedNeighboursMergeTransitively() {
        // A–B and B–C are each within threshold, A–C is not: still ONE cluster — a chain
        // of overlapping pins is unreadable as separate markers (documented choice).
        let result = clusters([
            Pin(name: "a", point: CGPoint(x: 0, y: 0)),
            Pin(name: "b", point: CGPoint(x: 40, y: 0)),
            Pin(name: "c", point: CGPoint(x: 80, y: 0)),
        ])
        XCTAssertEqual(result, [["a", "b", "c"]])
    }

    func testClusterAndMemberOrderFollowInput() {
        // "d" comes first in input, so its (far) cluster leads; the a/c cluster keeps
        // input order even though "b" sits between them spatially unrelated.
        let result = clusters([
            Pin(name: "d", point: CGPoint(x: 500, y: 500)),
            Pin(name: "a", point: CGPoint(x: 0, y: 0)),
            Pin(name: "b", point: CGPoint(x: 300, y: 0)),
            Pin(name: "c", point: CGPoint(x: 20, y: 0)),
        ])
        XCTAssertEqual(result, [["d"], ["a", "c"], ["b"]])
    }

    func testDeterministicAcrossRepeatedRuns() {
        let pins: [Pin] = (0..<30).map { (index: Int) -> Pin in
            let x = Double((index * 37) % 300)
            let y = Double((index * 53) % 300)
            return Pin(name: "p\(index)", point: CGPoint(x: x, y: y))
        }
        XCTAssertEqual(clusters(pins), clusters(pins))
    }

    func testUnprojectablePinsStaySingletons() {
        let result = clusters([
            Pin(name: "a", point: CGPoint(x: 0, y: 0)),
            Pin(name: "offscreen", point: nil),
            Pin(name: "b", point: CGPoint(x: 5, y: 5)),
        ])
        XCTAssertEqual(result, [["a", "b"], ["offscreen"]])
    }

    // MARK: - Centroid

    func testCentroidOfEmptyIsNil() {
        XCTAssertNil(MapPinClustering.centroid(of: []))
    }

    func testCentroidOfOneCoordinateIsItself() {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let centroid = MapPinClustering.centroid(of: [paris])
        XCTAssertEqual(centroid?.latitude, paris.latitude)
        XCTAssertEqual(centroid?.longitude, paris.longitude)
    }

    func testCentroidIsTheArithmeticMean() {
        let centroid = MapPinClustering.centroid(of: [
            CLLocationCoordinate2D(latitude: 10, longitude: 20),
            CLLocationCoordinate2D(latitude: 20, longitude: 40),
            CLLocationCoordinate2D(latitude: 30, longitude: 60),
        ])
        XCTAssertEqual(centroid?.latitude ?? .nan, 20, accuracy: 0.0001)
        XCTAssertEqual(centroid?.longitude ?? .nan, 40, accuracy: 0.0001)
    }

    // MARK: - Membership (representative choice)

    private struct Card: Identifiable, Equatable {
        var id: String
    }

    func testFirstMemberOfEachGroupIsTheRepresentative() {
        let groups = [
            MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), elements: [Card(id: "a"), Card(id: "b")]),
            MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1), elements: [Card(id: "c")]),
        ]
        let membership = MapPinClustering.membership(of: groups)

        XCTAssertEqual(membership["a"]?.isRepresentative, true)
        XCTAssertEqual(membership["b"]?.isRepresentative, false)
        XCTAssertEqual(membership["c"]?.isRepresentative, true, "a singleton is always its own representative")
    }

    func testMembershipMapsEveryElementToItsOwnGroup() {
        let groups = [
            MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), elements: [Card(id: "a"), Card(id: "b")]),
        ]
        let membership = MapPinClustering.membership(of: groups)
        XCTAssertEqual(membership["a"]?.group.elements.map(\.id), ["a", "b"])
        XCTAssertEqual(membership["b"]?.group.elements.map(\.id), ["a", "b"])
        XCTAssertNil(membership["unknown"])
    }

    // MARK: - Offsets (cluster split/merge glide)

    func testSingletonGroupHasZeroOffset() {
        let groups = [
            MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1), elements: [Card(id: "a")]),
        ]
        let offsets = MapPinClustering.offsets(
            of: groups,
            projectedElementPoint: { _ in CGPoint(x: 10, y: 10) },
            projectedCentroidPoint: { _ in CGPoint(x: 10, y: 10) }
        )
        XCTAssertEqual(offsets["a"], .zero)
    }

    func testClusteredMembersOffsetTowardTheSharedCentroid() {
        let groups = [
            MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), elements: [Card(id: "a"), Card(id: "b")]),
        ]
        let points: [String: CGPoint] = ["a": CGPoint(x: 0, y: 0), "b": CGPoint(x: 20, y: 0)]
        let offsets = MapPinClustering.offsets(
            of: groups,
            projectedElementPoint: { points[$0.id] },
            projectedCentroidPoint: { _ in CGPoint(x: 10, y: 0) }
        )
        XCTAssertEqual(offsets["a"], CGSize(width: 10, height: 0))
        XCTAssertEqual(offsets["b"], CGSize(width: -10, height: 0))
    }

    func testUnprojectableMemberIsOmittedRatherThanZero() {
        // The view treats a missing entry as `.zero`, but the pure function itself must
        // distinguish "couldn't project" from "happens to need no nudge" — otherwise a
        // genuinely off-screen member could get a wrong, confidently-computed offset.
        let groups = [
            MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), elements: [Card(id: "a")]),
        ]
        let offsets = MapPinClustering.offsets(
            of: groups,
            projectedElementPoint: { _ in nil },
            projectedCentroidPoint: { _ in CGPoint(x: 10, y: 0) }
        )
        XCTAssertNil(offsets["a"])
    }

    func testUnprojectableCentroidOmitsTheWholeGroup() {
        let groups = [
            MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), elements: [Card(id: "a"), Card(id: "b")]),
        ]
        let offsets = MapPinClustering.offsets(
            of: groups,
            projectedElementPoint: { _ in CGPoint(x: 0, y: 0) },
            projectedCentroidPoint: { _ in nil }
        )
        XCTAssertTrue(offsets.isEmpty)
    }

    func testOffsetsAreProjectionDependentSoMustBeRecomputedPerCameraSettle() {
        // The same cluster projected under two cameras yields different point vectors —
        // offsets computed at one camera are stale (wrong length and direction) at
        // another. This is why `CollectionMapView` recomputes offsets exactly when the
        // camera settles (`.onMapCameraChange(frequency: .onEnd)`): recomputing
        // mid-gesture would aim every glide at projections that stop being true a frame
        // later, and reusing pre-zoom offsets after the settle would glide along
        // wrong-looking pre-zoom vectors.
        let groups = [
            MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), elements: [Card(id: "a"), Card(id: "b")]),
        ]
        let zoomedOut: [String: CGPoint] = ["a": CGPoint(x: 100, y: 100), "b": CGPoint(x: 110, y: 100)]
        let zoomedIn: [String: CGPoint] = ["a": CGPoint(x: 50, y: 100), "b": CGPoint(x: 250, y: 100)]

        let before = MapPinClustering.offsets(
            of: groups,
            projectedElementPoint: { zoomedOut[$0.id] },
            projectedCentroidPoint: { _ in CGPoint(x: 105, y: 100) }
        )
        let after = MapPinClustering.offsets(
            of: groups,
            projectedElementPoint: { zoomedIn[$0.id] },
            projectedCentroidPoint: { _ in CGPoint(x: 150, y: 100) }
        )

        XCTAssertEqual(before["a"], CGSize(width: 5, height: 0))
        XCTAssertEqual(after["a"], CGSize(width: 100, height: 0))
        XCTAssertNotEqual(before["b"], after["b"], "a zoom changes every member's offset vector")
    }
}
