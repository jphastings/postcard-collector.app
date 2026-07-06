import Foundation

/// The distribution math behind `MasonryGrid`: postcards have varied aspect ratios, so a
/// uniform grid wastes vertical space — instead items are dealt into N equal-width columns,
/// each new item going to the currently-shortest column. Heights come from the cards' KNOWN
/// pixel aspect ratios (`CardSummary.frontPxW/H`), so layout never needs an image decode.
enum MasonryLayout {
    /// Greedy shortest-column distribution, in input order. Deterministic: ties go to the
    /// leftmost shortest column. An item's relative height in an equal-width column is
    /// `1 / aspectRatio` (aspect ratio = width/height); non-positive ratios are treated as
    /// square rather than corrupting the running heights.
    static func columns<Item>(
        of items: [Item],
        count: Int,
        aspectRatio: (Item) -> Double
    ) -> [[Item]] {
        let count = max(count, 1)
        var columns = [[Item]](repeating: [], count: count)
        var heights = [Double](repeating: 0, count: count)

        for item in items {
            let ratio = aspectRatio(item)
            let height = ratio > 0 ? 1 / ratio : 1
            // `min(by:)` keeps the FIRST minimal element, which is what makes ties (and
            // therefore the whole layout) deterministic.
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(item)
            heights[shortest] += height
        }

        return columns
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
