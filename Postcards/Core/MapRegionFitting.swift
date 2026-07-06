import CoreLocation
import MapKit

/// Computes an initial camera region for `CollectionMapView` that frames every pin in a
/// collection at once, with some breathing room so pins don't sit flush against the map's
/// edge.
enum MapRegionFitting {
    /// The minimum span used for a single coordinate (or several identical ones) — without
    /// a floor here, a one-pin collection would zoom in absurdly close (span 0).
    static let minimumSpanDegrees: Double = 0.05

    /// Extra headroom added on each side of the tight bounding box, as a fraction of its
    /// span.
    static let paddingFraction: Double = 0.25

    /// `nil` for an empty list — callers should fall back to `.automatic`/some default
    /// camera position rather than treat that as an error.
    static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coordinates.isEmpty else { return nil }

        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min()!
        let maxLatitude = latitudes.max()!
        let minLongitude = longitudes.min()!
        let maxLongitude = longitudes.max()!

        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let latitudeDelta = max((maxLatitude - minLatitude) * (1 + paddingFraction), minimumSpanDegrees)
        let longitudeDelta = max((maxLongitude - minLongitude) * (1 + paddingFraction), minimumSpanDegrees)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}
