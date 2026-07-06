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
        }
    }
}
