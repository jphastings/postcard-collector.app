import SwiftUI

/// A masonry (Pinterest-style) grid: SwiftUI has no built-in one, so this is the standard
/// robust construction — a ScrollView holding an HStack of N equal-width LazyVStack
/// columns, with items dealt to the currently-shortest column by their KNOWN aspect ratios
/// (see `MasonryLayout`; no image decode is needed for layout). Postcards vary a lot in
/// aspect ratio, so this wastes far less space than a uniform grid.
///
/// Reading order is column-balanced rather than strict rows — items enter in the given
/// order, so it still reads roughly left-to-right, top-to-bottom.
struct MasonryGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let aspectRatio: (Item) -> Double
    @ViewBuilder let content: (Item) -> Content

    private let spacing: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let columnCount = MasonryLayout.columnCount(
                forAvailableWidth: proxy.size.width - spacing * 2,
                spacing: spacing
            )
            let columns = MasonryLayout.columns(of: items, count: columnCount, aspectRatio: aspectRatio)

            ScrollView {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        LazyVStack(spacing: spacing) {
                            ForEach(column) { item in
                                content(item)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(spacing)
            }
            .stableScrollEdgeEffect()
        }
    }
}

private extension View {
    /// iOS 26's Liquid Glass "scroll edge effect" (on by default once built against the
    /// iOS 26 SDK) crashes while laying out this masonry ScrollView — a vertical ScrollView
    /// whose content is an HStack of LazyVStacks: `-[UIScrollView _updatePockets]`
    /// over-releases a `ScrollEdgeEffectView` during `removeFromSuperview`, aborting on
    /// `objc_unsafeClaimAutoreleasedReturnValue`. The `.hard` style renders the edge without
    /// that soft-effect view lifecycle, sidestepping the crash.
    @ViewBuilder
    func stableScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .all)
        } else {
            self
        }
    }
}
