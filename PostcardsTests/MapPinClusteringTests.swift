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

    // MARK: - FLIP deltas (cluster split/merge glide)

    /// Fixed screen projection for delta tests: 10 points per degree on each axis.
    private func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint? {
        CGPoint(x: coordinate.longitude * 10, y: coordinate.latitude * -10)
    }

    func testSplitMembersGetTheInverseDeltaFromCentroidToOwnCoordinate() {
        // A 2-cluster at centroid (0, 5) splits into singletons at (0,0) and (0,10):
        // each pin's new anchor is its own coordinate, and the inverse delta points BACK
        // at the old centroid — applied as an initial offset and animated to zero, the
        // pin glides centroid → own spot.
        let centroid = CLLocationCoordinate2D(latitude: 0, longitude: 5)
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 0, longitude: 10)
        let old = [MapPinGroup(coordinate: centroid, elements: [Card(id: "a"), Card(id: "b")])]
        let new = [
            MapPinGroup(coordinate: a, elements: [Card(id: "a")]),
            MapPinGroup(coordinate: b, elements: [Card(id: "b")]),
        ]

        let deltas = MapPinClustering.flipDeltas(from: old, to: new, projectedPoint: project)

        XCTAssertEqual(deltas["a"], CGSize(width: 50, height: 0), "a's old point (50) minus its new point (0)")
        XCTAssertEqual(deltas["b"], CGSize(width: -50, height: 0), "b's old point (50) minus its new point (100)")
    }

    func testMergeIsTheSameTransitionInReverse() {
        let centroid = CLLocationCoordinate2D(latitude: 0, longitude: 5)
        let a = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let b = CLLocationCoordinate2D(latitude: 0, longitude: 10)
        let singles = [
            MapPinGroup(coordinate: a, elements: [Card(id: "a")]),
            MapPinGroup(coordinate: b, elements: [Card(id: "b")]),
        ]
        let merged = [MapPinGroup(coordinate: centroid, elements: [Card(id: "a"), Card(id: "b")])]

        let deltas = MapPinClustering.flipDeltas(from: singles, to: merged, projectedPoint: project)

        XCTAssertEqual(deltas["a"], CGSize(width: -50, height: 0))
        XCTAssertEqual(deltas["b"], CGSize(width: 50, height: 0))
    }

    func testUnmovedDisplayCoordinateGetsNoDelta() {
        // A pin whose display coordinate didn't change has nothing to glide — no entry,
        // so the view never even perturbs its offset.
        let spot = CLLocationCoordinate2D(latitude: 3, longitude: 3)
        let old = [MapPinGroup(coordinate: spot, elements: [Card(id: "a")])]
        let new = [MapPinGroup(coordinate: spot, elements: [Card(id: "a")])]
        XCTAssertTrue(MapPinClustering.flipDeltas(from: old, to: new, projectedPoint: project).isEmpty)
    }

    func testFreshElementGetsNoDelta() {
        // An element with no old group (just appeared — e.g. a search widened) must not
        // fly in from anywhere; it simply appears at its anchor.
        let old: [MapPinGroup<Card>] = []
        let new = [MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1), elements: [Card(id: "a")])]
        XCTAssertTrue(MapPinClustering.flipDeltas(from: old, to: new, projectedPoint: project).isEmpty)
    }

    func testUnprojectableEndpointGetsNoDeltaRatherThanAWrongOne() {
        let old = [MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 5), elements: [Card(id: "a")])]
        let new = [MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), elements: [Card(id: "a")])]
        let deltas = MapPinClustering.flipDeltas(from: old, to: new) { _ in nil }
        XCTAssertTrue(deltas.isEmpty, "no glide beats a confidently-wrong one for an off-screen pin")
    }

    func testDeltasAreProjectedAtOneCamera() {
        // Both endpoints project through the SAME closure — the settled camera. A delta
        // is only meaningful at the camera it was projected under, which is why
        // `CollectionMapView` computes them exactly at `.onEnd` and snaps them away the
        // moment a new gesture begins.
        let old = [MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 5), elements: [Card(id: "a")])]
        let new = [MapPinGroup(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), elements: [Card(id: "a")])]

        let atOneZoom = MapPinClustering.flipDeltas(from: old, to: new) { CGPoint(x: $0.longitude * 10, y: 0) }
        let atAnother = MapPinClustering.flipDeltas(from: old, to: new) { CGPoint(x: $0.longitude * 40, y: 0) }

        XCTAssertEqual(atOneZoom["a"], CGSize(width: 50, height: 0))
        XCTAssertEqual(atAnother["a"], CGSize(width: 200, height: 0), "the same geographic move is a different pixel vector at a different zoom")
    }
}
