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
            .quietGridInteractions()
        }
    }
}

private extension View {
    /// This masonry ScrollView — a vertical ScrollView whose content is an HStack of
    /// LazyVStacks of asynchronously-loading Button cells — trips two iOS 26 UIKit bugs while
    /// its cells materialise and recycle during layout. Both are quieted by turning OFF the
    /// two Liquid Glass effects the grid doesn't need anyway (the rest of the app keeps its
    /// Liquid Glass look):
    ///
    /// 1. Scroll edge effect → `.hard`: the default soft effect churns a `ScrollEdgeEffectView`
    ///    in `-[UIScrollView _updatePockets]` and over-releases it. A grid of die-cut
    ///    thumbnails doesn't want a soft glass fade at its edges regardless.
    /// 2. Hover effect → disabled: iOS gives each cell Button a pointer/hover effect, and
    ///    `-[_UIPointerInteractionAssistant _assistantForView:]` reads a recycled cell's freed
    ///    layer while monitoring them. There's no pointer on iPhone and the grid has its own
    ///    selection highlight, so the per-cell hover effect is unnecessary.
    @ViewBuilder
    func quietGridInteractions() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .all).hoverEffectDisabled()
        } else {
            hoverEffectDisabled()
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.hard, for: .all)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
