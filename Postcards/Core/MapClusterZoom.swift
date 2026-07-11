import CoreLocation
import MapKit

/// What tapping a multi-card pin should do: zoom the camera in on a region that would
/// actually pull its members apart on screen, or — if they're packed too tightly for that
/// to be worth doing — cycle through them instead (driven from
/// `CollectionMapView.pinClicked`, via `MapPinRotation`).
///
/// Pure and coordinate-only — no live `MapProxy` or screen geometry involved — so it's
/// testable without hosting a map: it bounds the members' OWN coordinates (not the
/// cluster's shared centroid) to decide the region's SPAN and whether zooming is even
/// worth doing, comparing the padded box's corner-to-corner distance against
/// `minimumUsefulSpanMeters`. Below that, even a tight, close-in camera wouldn't
/// meaningfully separate the members — it would sit closer than makes sense for browsing
/// a postcard collection, and the next settle's clustering would likely just re-merge
/// them anyway — so cycling serves the user better than reframing to a view that's barely
/// different from the current one. Identical coordinates are the limit case (zero span)
/// and always fall into `.cycle`: no camera, however tight, ever splits a stack sitting on
/// one exact point.
///
/// The resulting camera, when it does zoom, is always CENTRED ON THE PIN'S OWN DISPLAYED
/// COORDINATE (its cluster's centroid — see `MapPinGroup.coordinate`), not the members'
/// bounding-box centre: the tap originates from that exact pin, so re-centring on the
/// members' box instead would visibly jump the camera away from the spot the user just
/// tapped. The span is still sized from the members' own spread, just measured as each
/// axis's furthest deviation FROM that centre (doubled, since the centre isn't necessarily
/// in the middle of the members), so the recentred region still contains every member.
enum MapClusterZoom {
    /// Extra headroom added on each side of the members' span from the pin's centre, as a
    /// fraction of that span — mirrors `MapRegionFitting.paddingFraction`'s role, tuned a
    /// touch larger since this box can be tiny and benefits from more relative breathing
    /// room.
    static let paddingFraction: Double = 0.3
    /// Below this corner-to-corner span, zooming in on the members isn't a useful camera
    /// move (see the type's doc comment).
    static let minimumUsefulSpanMeters: CLLocationDistance = 5_000
    /// Degrees-floor for an axis with no spread at all (e.g. every member shares a
    /// latitude exactly), so the padded region is never degenerate on that axis.
    static let minimumAxisSpanDegrees: Double = 0.01

    enum Decision {
        case zoom(MKCoordinateRegion)
        case cycle
    }

    /// - Parameters:
    ///   - coordinates: The cluster members' own coordinates — used only to size the
    ///     region's span (see the type's doc comment).
    ///   - center: The pin's own displayed coordinate (its cluster's centroid) — the
    ///     camera always recentres here, never on the members' bounding-box centre.
    static func decision(for coordinates: [CLLocationCoordinate2D], centeredOn center: CLLocationCoordinate2D) -> Decision {
        guard let box = BoundingBox(of: coordinates) else { return .cycle }
        let span = CLLocation(latitude: box.minLatitude, longitude: box.minLongitude)
            .distance(from: CLLocation(latitude: box.maxLatitude, longitude: box.maxLongitude))
        guard span >= minimumUsefulSpanMeters else { return .cycle }
        return .zoom(box.paddedRegion(centeredOn: center, paddingFraction: paddingFraction, minimumAxisSpanDegrees: minimumAxisSpanDegrees))
    }

    private struct BoundingBox {
        var minLatitude: Double
        var maxLatitude: Double
        var minLongitude: Double
        var maxLongitude: Double

        init?(of coordinates: [CLLocationCoordinate2D]) {
            guard !coordinates.isEmpty else { return nil }
            let latitudes = coordinates.map(\.latitude)
            let longitudes = coordinates.map(\.longitude)
            minLatitude = latitudes.min()!
            maxLatitude = latitudes.max()!
            minLongitude = longitudes.min()!
            maxLongitude = longitudes.max()!
        }

        /// Sized from each axis's furthest member deviation FROM `center` (not from this
        /// box's own midpoint), doubled to cover both sides symmetrically around `center` —
        /// so every member stays inside the region despite it being recentred away from
        /// the members' own bounding-box centre.
        func paddedRegion(
            centeredOn center: CLLocationCoordinate2D,
            paddingFraction: Double,
            minimumAxisSpanDegrees: Double
        ) -> MKCoordinateRegion {
            let latitudeDeviation = max(abs(maxLatitude - center.latitude), abs(minLatitude - center.latitude))
            let longitudeDeviation = max(abs(maxLongitude - center.longitude), abs(minLongitude - center.longitude))
            let latitudeDelta = max(latitudeDeviation * 2 * (1 + paddingFraction), minimumAxisSpanDegrees)
            let longitudeDelta = max(longitudeDeviation * 2 * (1 + paddingFraction), minimumAxisSpanDegrees)
            return MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
        }
    }
}
