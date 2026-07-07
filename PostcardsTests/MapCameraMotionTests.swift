import MapKit
import SwiftUI
import XCTest

/// The snap-on-gesture rule's gatekeeper (see `CollectionMapView`): a `.continuous`
/// camera event cancels an in-flight cluster glide ONLY on material movement. The settle's
/// own echo — whose delivery order against `.onEnd` isn't contractual, and whose camera
/// carries floating-point drift from MapKit's projection round-trips — must never be
/// classified as motion, or it kills every glide on the frame it starts (the teleport bug).
final class MapCameraMotionTests: XCTestCase {
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

    func testExactEchoIsNotMaterial() {
        XCTAssertFalse(MapCameraMotion.isMaterialMotion(camera(), since: camera()))
    }

    func testFloatingPointDriftedEchoIsNotMaterial() {
        // Regression test for the teleport bug: the settle echo's camera differs from the
        // recorded one by tiny FP drift; an exact-equality comparison classified this as
        // real motion and cancelled the glide on the frame it began.
        let settled = camera()
        let drifted = camera(
            latitude: 25.1972 + 1e-10,
            longitude: 55.2744 - 1e-10,
            distance: 10_000 * (1 + 1e-9),
            heading: 1e-10,
            pitch: 1e-10
        )
        XCTAssertFalse(MapCameraMotion.isMaterialMotion(drifted, since: settled))
    }

    func testDriftJustInsideTheToleranceIsNotMaterial() {
        // 0.05% altitude change: within the 0.1% band, far above FP noise, far below any
        // real gesture.
        XCTAssertFalse(MapCameraMotion.isMaterialMotion(camera(distance: 10_000 * 1.0005), since: camera()))
    }

    func testScrollWheelZoomIsMaterial() {
        // A single scroll tick changes the camera distance by several percent.
        XCTAssertTrue(MapCameraMotion.isMaterialMotion(camera(distance: 9_500), since: camera()))
        XCTAssertTrue(MapCameraMotion.isMaterialMotion(camera(distance: 10_500), since: camera()))
    }

    func testPanIsMaterial() {
        // ~0.01° of latitude is ~1.1km — a real pan at a 10km camera.
        XCTAssertTrue(MapCameraMotion.isMaterialMotion(camera(latitude: 25.2072), since: camera()))
        XCTAssertTrue(MapCameraMotion.isMaterialMotion(camera(longitude: 55.2844), since: camera()))
    }

    func testHeadingAndPitchChangesAreMaterial() {
        XCTAssertTrue(MapCameraMotion.isMaterialMotion(camera(heading: 5), since: camera()))
        XCTAssertTrue(MapCameraMotion.isMaterialMotion(camera(pitch: 5), since: camera()))
    }

    func testNothingSettledYetIsAlwaysMotion() {
        // Before the first settle there's no glide to protect; treating every event as
        // motion is the safe default.
        XCTAssertTrue(MapCameraMotion.isMaterialMotion(camera(), since: nil))
    }
}
