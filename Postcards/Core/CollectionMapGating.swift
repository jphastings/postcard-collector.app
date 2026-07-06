import CoreGraphics
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

/// Sizing math for the compact card shown when a map pin is selected: `FlippableCardView`
/// fits itself into whatever frame it's given, so this just picks that frame — the front ∪
/// back bounding box (see `FlipGeometry.boundingSize`), scaled so its longer side matches
/// `targetLongestSide`.
enum MiniCardSizing {
    static let defaultTargetLongestSide: CGFloat = 180

    static func frameSize(
        forFrontSize frontSize: CGSize,
        flip: Flip,
        targetLongestSide: CGFloat = defaultTargetLongestSide
    ) -> CGSize {
        let bounding = FlipGeometry.boundingSize(forFrontSize: frontSize, flip: flip)
        guard bounding.width > 0, bounding.height > 0 else {
            return CGSize(width: targetLongestSide, height: targetLongestSide)
        }
        let scale = targetLongestSide / max(bounding.width, bounding.height)
        return CGSize(width: bounding.width * scale, height: bounding.height * scale)
    }
}
