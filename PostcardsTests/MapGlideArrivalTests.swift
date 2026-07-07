import XCTest

/// The decision behind per-member glide-completion reporting (see `GlideOffsetEffect` in
/// `CollectionMapView`): a pin "arrives" only when it was genuinely gliding AND its
/// animated progress has reached the terminal band around zero — the merge choreography's
/// badge/visibility resolution waits for every member's arrival, so this predicate is
/// what keeps stacked pins visible for the full glide.
final class MapGlideArrivalTests: XCTestCase {
    private let gliding = CGSize(width: 40, height: -25)

    func testTerminalProgressWithARealDeltaArrives() {
        XCTAssertTrue(MapGlideArrival.hasArrived(progress: 0, delta: gliding))
        XCTAssertTrue(MapGlideArrival.hasArrived(progress: MapGlideArrival.terminalProgress, delta: gliding))
    }

    func testMidFlightNeverArrives() {
        XCTAssertFalse(MapGlideArrival.hasArrived(progress: 0.5, delta: gliding))
        XCTAssertFalse(MapGlideArrival.hasArrived(progress: 0.01, delta: gliding), "close is not arrived — resolution mid-glide is the vanishing-pins bug")
    }

    func testPhaseOneSnapIsNotAnArrival() {
        // The snap to full inverse offset is the START of the glide.
        XCTAssertFalse(MapGlideArrival.hasArrived(progress: 1, delta: gliding))
    }

    func testPinsThatNeverMovedNeverArrive() {
        // Zero delta = not part of this glide: its progress is meaningless, and an
        // interrupt clears deltas precisely so no further reports count.
        XCTAssertFalse(MapGlideArrival.hasArrived(progress: 0, delta: .zero))
    }
}
