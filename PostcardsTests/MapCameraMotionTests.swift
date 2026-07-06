import MapKit
import SwiftUI
import XCTest

/// The snap-on-gesture rule's gatekeeper (see `CollectionMapView`): a `.continuous`
/// camera event cancels an in-flight cluster glide ONLY if it's a real movement, not the
/// settle's own echo — otherwise the echo (whose delivery order against `.onEnd` isn't
/// contractual) could kill every glide on the frame it starts.
final class MapCameraMotionTests: XCTestCase {
    private let dubai = CLLocationCoordinate2D(latitude: 25.1972, longitude: 55.2744)

    private func camera(
        latitude: Double = 25.1972,
        longitude: Double = 55.2744,
        distance: Double = 10_000,
        heading: Double = 0,
        pitch: Double = 0
    ) -> MapCamera {
        MapCamera(
            centerCoordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            distance: distance,
            heading: heading,
            pitch: pitch
        )
    }

    func testIdenticalCameraIsTheSettleEcho() {
        XCTAssertTrue(MapCameraMotion.isSettledEcho(camera(), of: camera()))
    }

    func testAnyChangedComponentIsRealMotion() {
        let settled = camera()
        XCTAssertFalse(MapCameraMotion.isSettledEcho(camera(latitude: 25.2), of: settled))
        XCTAssertFalse(MapCameraMotion.isSettledEcho(camera(longitude: 55.3), of: settled))
        XCTAssertFalse(MapCameraMotion.isSettledEcho(camera(distance: 9_000), of: settled), "a scroll-wheel zoom changes distance first")
        XCTAssertFalse(MapCameraMotion.isSettledEcho(camera(heading: 45), of: settled))
        XCTAssertFalse(MapCameraMotion.isSettledEcho(camera(pitch: 30), of: settled))
    }

    func testNothingSettledYetIsNeverAnEcho() {
        // Before the first settle there's no glide to protect; treating every event as
        // motion is the safe default.
        XCTAssertFalse(MapCameraMotion.isSettledEcho(camera(), of: nil))
    }
}
