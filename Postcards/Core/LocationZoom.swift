import MapKit

/// Chooses a camera zoom for a resolved `LocationSearchField` result, so a street address
/// doesn't recenter the map as wide as a country would. `MKLocalSearch.Response.boundingRegion`
/// is preferred when it's usable (see `isSaneBoundingSpan`); `spanMeters` is the fallback,
/// keyed off which placemark fields resolved. Kept in Core — `MKCoordinateSpan` and
/// `MKCoordinateRegion` are plain value types, so this stays testable without a live search.
enum LocationZoom {
    /// Fallback zoom, in meters, keyed to placemark granularity — checked most to least
    /// specific: a resolved street implies a few km is enough, a resolved city/town tens of
    /// km, a resolved state/region a few hundred km, and anything coarser (or nothing at all)
    /// a continental span.
    static func spanMeters(hasThoroughfare: Bool, hasLocality: Bool, hasAdministrativeArea: Bool) -> Double {
        if hasThoroughfare { return 4_000 }
        if hasLocality { return 40_000 }
        if hasAdministrativeArea { return 300_000 }
        return 1_500_000
    }

    /// Whether a `boundingRegion`'s span is usable as a zoom target. MapKit's documented
    /// fallback for a match with no natural bounding box is a region spanning the entire
    /// globe, and a zero/degenerate span is equally useless as a camera target — both should
    /// fall through to the `spanMeters` heuristic instead.
    static func isSaneBoundingSpan(_ span: MKCoordinateSpan) -> Bool {
        guard span.latitudeDelta.isFinite, span.longitudeDelta.isFinite else { return false }
        return span.latitudeDelta > 0 && span.latitudeDelta < 90
            && span.longitudeDelta > 0 && span.longitudeDelta < 180
    }
}
