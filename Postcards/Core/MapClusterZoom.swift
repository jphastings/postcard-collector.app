import CoreLocation
import MapKit

/// What tapping a multi-card pin should do: zoom the camera in on a region that would
/// actually pull its members apart on screen, or — if they're packed too tightly for that
/// to be worth doing — cycle through them instead (driven from
/// `CollectionMapView.pinClicked`, via `MapPinRotation`).
///
/// Pure and coordinate-only — no live `MapProxy` or screen geometry involved — so it's
/// testable without hosting a map: it bounds the members' OWN coordinates (not the
/// cluster's shared centroid, which is a single point and says nothing about their
/// spread), pads the box by `paddingFraction` on each axis the same way
/// `MapRegionFitting` frames the whole collection, and compares the padded box's
/// corner-to-corner distance against `minimumUsefulSpanMeters`. Below that, even a tight,
/// close-in camera wouldn't meaningfully separate the members — it would sit closer than
/// makes sense for browsing a postcard collection, and the next settle's clustering would
/// likely just re-merge them anyway — so cycling serves the user better than reframing to
/// a view that's barely different from the current one. Identical coordinates are the
/// limit case (zero span) and always fall into `.cycle`: no camera, however tight, ever
/// splits a stack sitting on one exact point.
enum MapClusterZoom {
    /// Extra headroom added on each side of the members' tight bounding box, as a
    /// fraction of its span — mirrors `MapRegionFitting.paddingFraction`'s role, tuned a
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

    static func decision(for coordinates: [CLLocationCoordinate2D]) -> Decision {
        guard let box = BoundingBox(of: coordinates) else { return .cycle }
        let span = CLLocation(latitude: box.minLatitude, longitude: box.minLongitude)
            .distance(from: CLLocation(latitude: box.maxLatitude, longitude: box.maxLongitude))
        guard span >= minimumUsefulSpanMeters else { return .cycle }
        return .zoom(box.paddedRegion(paddingFraction: paddingFraction, minimumAxisSpanDegrees: minimumAxisSpanDegrees))
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

        func paddedRegion(paddingFraction: Double, minimumAxisSpanDegrees: Double) -> MKCoordinateRegion {
            let center = CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            )
            let latitudeDelta = max((maxLatitude - minLatitude) * (1 + paddingFraction), minimumAxisSpanDegrees)
            let longitudeDelta = max((maxLongitude - minLongitude) * (1 + paddingFraction), minimumAxisSpanDegrees)
            return MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
        }
    }
}
