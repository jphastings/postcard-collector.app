import MapKit
// MapCamera lives in MapKit's SwiftUI overlay, which only surfaces when SwiftUI is also
// imported.
import SwiftUI

/// Distinguishes a REAL camera movement (a gesture beginning, which must snap any
/// in-flight cluster glide and resolve its choreography — see `CollectionMapView`'s doc
/// comment) from the redundant continuous-frequency echo of a settle: `Map` delivers the
/// final camera to BOTH `.onMapCameraChange` frequencies, and the relative order of the
/// two callbacks isn't contractual — if the `.continuous` echo lands after the `.onEnd`
/// handler has started a glide, treating it as a gesture kills that glide on the very
/// frame it began (pins teleport instead of gliding).
///
/// The comparison is TOLERANCED, not exact: the echo's camera can differ from the one
/// the settle recorded by floating-point drift (MapKit round-trips the camera through
/// its own projection math between the two deliveries), and an exact-equality check
/// classified that drift as real motion — the teleport bug. Any genuine gesture exceeds
/// these tolerances within its first frame: a single scroll-wheel zoom tick changes
/// distance by several percent, a pan moves the centre by a large fraction of the
/// viewport.
enum MapCameraMotion {
    /// Centre and altitude tolerance, as a fraction of the settled camera's distance:
    /// 0.1% of altitude (10m at a 10km camera) is orders of magnitude above FP drift and
    /// well below the smallest gesture MapKit reports.
    static let relativeTolerance = 0.001
    /// Heading/pitch tolerance in degrees.
    static let angularToleranceDegrees = 0.1

    /// Whether `camera` differs MATERIALLY from the camera recorded at the last settle —
    /// i.e. a gesture is genuinely underway, not just the settle echoing back with FP
    /// drift. `true` when nothing has settled yet: before the first settle there's no
    /// glide to protect, so treating everything as motion is the safe default.
    static func isMaterialMotion(_ camera: MapCamera, since settled: MapCamera?) -> Bool {
        guard let settled else { return true }
        let tolerance = max(settled.distance, 1) * relativeTolerance
        let centerDrift = MKMapPoint(camera.centerCoordinate).distance(to: MKMapPoint(settled.centerCoordinate))
        return centerDrift > tolerance
            || abs(camera.distance - settled.distance) > tolerance
            || abs(camera.heading - settled.heading) > angularToleranceDegrees
            || abs(camera.pitch - settled.pitch) > angularToleranceDegrees
    }
}
