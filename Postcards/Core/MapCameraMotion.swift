import MapKit
// MapCamera lives in MapKit's SwiftUI overlay, which only surfaces when SwiftUI is also
// imported.
import SwiftUI

/// Distinguishes a REAL camera movement (a gesture beginning, which must snap any
/// in-flight cluster glide to zero — see `CollectionMapView`'s doc comment) from the
/// redundant continuous-frequency echo of a settle: `Map` delivers the final camera to
/// BOTH `.onMapCameraChange` frequencies, and the relative order of the two callbacks
/// isn't contractual — if the `.continuous` echo lands after the `.onEnd` handler has
/// started a glide, treating it as a gesture would kill that glide on the very frame it
/// began. The echo carries exactly the camera the settle recorded, so an exact-equality
/// comparison filters it; any genuine gesture differs immediately.
enum MapCameraMotion {
    /// Whether `camera` is byte-for-byte the camera recorded at the last settle. `false`
    /// when nothing has settled yet — before the first settle there's no glide to protect,
    /// so treating everything as motion is harmless.
    static func isSettledEcho(_ camera: MapCamera, of settled: MapCamera?) -> Bool {
        guard let settled else { return false }
        return camera.centerCoordinate.latitude == settled.centerCoordinate.latitude
            && camera.centerCoordinate.longitude == settled.centerCoordinate.longitude
            && camera.distance == settled.distance
            && camera.heading == settled.heading
            && camera.pitch == settled.pitch
    }
}
