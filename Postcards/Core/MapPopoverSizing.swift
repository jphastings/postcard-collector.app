import CoreGraphics

/// Height budget for a map pin's name-list popover (see `CollectionMapView`): capped so a
/// pin with many co-located cards doesn't grow taller than is comfortable to read, or taller
/// than the map itself on a short/narrow pane. Kept pure and separate from the view so the
/// cap math is testable without SwiftUI/MapKit — the view just calls this and wraps any
/// overflow in a `ScrollView`.
enum MapPopoverSizing {
    /// A rough single-row height (callout text plus the row's vertical padding), used only
    /// to translate "about six rows" into points. Not a pixel-exact measurement — the real
    /// row height varies with Dynamic Type and is left to size itself normally under the cap.
    static let approximateRowHeight: CGFloat = 32
    static let maxVisibleRows = 6
    /// Never more than this fraction of the map's own height, so a huge cluster's list can't
    /// overwhelm a short map pane regardless of the row-count cap above.
    static let maxHeightFraction: CGFloat = 0.5

    /// The smaller of "about `maxVisibleRows` rows" and `maxHeightFraction` of whatever
    /// height the map has to offer. Non-positive or NaN input maps to 0 (no space to offer,
    /// so nothing is reserved) rather than propagating a negative or undefined frame.
    static func maxHeight(forAvailableHeight availableHeight: CGFloat) -> CGFloat {
        guard !availableHeight.isNaN, availableHeight > 0 else { return 0 }
        return min(CGFloat(maxVisibleRows) * approximateRowHeight, availableHeight * maxHeightFraction)
    }
}
