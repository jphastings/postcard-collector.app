import CoreLocation

/// Whether a collection has anything worth putting on a map, and what to put there — kept
/// separate from `CollectionMapView` so it's testable without SwiftUI/MapKit.
enum CollectionMapGating {
    /// The mode switcher (see `CollectionModeSwitcher`) is only enabled once at least one
    /// card in the collection carries a coordinate.
    static func isEnabled(for cards: [CardSummary]) -> Bool {
        cards.contains { $0.coordinate != nil }
    }

    /// Every coordinate present among `cards`, in the same order — for feeding
    /// `MapRegionFitting` or counting pins.
    static func coordinates(in cards: [CardSummary]) -> [CLLocationCoordinate2D] {
        cards.compactMap(\.coordinate)
    }
}
