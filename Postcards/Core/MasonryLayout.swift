import Foundation

/// The geometry behind `MasonryGrid`: postcards have varied aspect ratios, so a uniform grid
/// wastes vertical space — instead items are dealt into N equal-width columns, each new item
/// going to the currently-shortest column. Heights come from the cards' KNOWN pixel aspect
/// ratios (`CardSummary.frontPxW/H`), so the whole layout is known before anything renders
/// and never needs an image decode.
enum MasonryLayout {
    struct Placement: Equatable {
        /// One per input item, in input order, relative to the content's top-leading corner.
        var frames: [CGRect]
        var contentHeight: Double
    }

    /// Greedy shortest-column placement, in input order. Deterministic: ties go to the
    /// leftmost shortest column, and an item's frame depends only on the items before it, so
    /// appending never moves anything already placed. Aspect ratio is width/height;
    /// non-positive ratios are treated as square rather than corrupting the running heights.
    static func placement<Item>(
        of items: [Item],
        width: Double,
        columnCount: Int,
        spacing: Double,
        aspectRatio: (Item) -> Double
    ) -> Placement {
        let count = max(columnCount, 1)
        let columnWidth = max((width - spacing * Double(count - 1)) / Double(count), 0)
        // A spacing above the top, so each column's first item lands at y = 0.
        var bottoms = [Double](repeating: -spacing, count: count)
        var frames: [CGRect] = []
        frames.reserveCapacity(items.count)

        for item in items {
            let ratio = aspectRatio(item)
            let height = columnWidth / (ratio > 0 ? ratio : 1)
            // `min(by:)` keeps the FIRST minimal element, which is what makes ties (and
            // therefore the whole layout) deterministic.
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] } ?? 0
            let y = bottoms[column] + spacing
            frames.append(CGRect(x: Double(column) * (columnWidth + spacing), y: y, width: columnWidth, height: height))
            bottoms[column] = y + height
        }

        return Placement(frames: frames, contentHeight: max(bottoms.max() ?? 0, 0))
    }

    /// The vertical span of content worth rendering for a scroll position: what's on screen
    /// plus at least a viewport above and below. Snapped to half-viewport steps, so it only
    /// changes (and the grid only re-renders) every half screen of scrolling.
    static func renderSpan(scrollOffset: Double, viewportHeight: Double) -> ClosedRange<Double> {
        let step = max(viewportHeight, 1) / 2
        let band = (scrollOffset / step).rounded(.down)
        return (band - 2) * step...(band + 5) * step
    }

    /// How many columns fit the available content width at roughly `targetColumnWidth`
    /// per column: floor((width + spacing) / (target + spacing)). Two columns are kept
    /// down to `minimumColumnWidth` each (comfortably below the target, so an iPhone in
    /// portrait still gets two); once even that no longer fits — narrow split-view panes —
    /// the layout drops to a single full-width column rather than squeezing two unusably
    /// narrow ones.
    static func columnCount(
        forAvailableWidth width: Double,
        targetColumnWidth: Double = 180,
        minimumColumnWidth: Double = 150,
        spacing: Double = 16
    ) -> Int {
        guard width >= minimumColumnWidth * 2 + spacing else { return 1 }
        let fitted = Int((width + spacing) / (targetColumnWidth + spacing))
        return max(fitted, 2)
    }
}
