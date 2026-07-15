import SwiftUI

/// A masonry (Pinterest-style) grid: SwiftUI has no built-in one, so this is the standard
/// robust construction — a ScrollView holding an HStack of N equal-width LazyVStack
/// columns, with items dealt to the currently-shortest column by their KNOWN aspect ratios
/// (see `MasonryLayout`; no image decode is needed for layout). Postcards vary a lot in
/// aspect ratio, so this wastes far less space than a uniform grid.
///
/// Reading order is column-balanced rather than strict rows — items enter in the given
/// order, so it still reads roughly left-to-right, top-to-bottom.
struct MasonryGrid<Item: Identifiable, Content: View, Header: View>: View {
    let items: [Item]
    let aspectRatio: (Item) -> Double
    let header: Header
    @ViewBuilder let content: (Item) -> Content

    private let spacing: CGFloat = 16

    init(
        items: [Item],
        aspectRatio: @escaping (Item) -> Double,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.aspectRatio = aspectRatio
        self.header = header()
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let columnCount = MasonryLayout.columnCount(
                forAvailableWidth: proxy.size.width - spacing * 2,
                spacing: spacing
            )
            let columns = MasonryLayout.columns(of: items, count: columnCount, aspectRatio: aspectRatio)

            ScrollView {
                // The header (e.g. a collection's name) scrolls with the grid rather than sitting
                // in fixed chrome, so it slides off-screen as the user scrolls into the cards. The
                // per-column `LazyVStack`s below keep cell rendering lazy regardless of this outer
                // plain `VStack`.
                VStack(alignment: .leading, spacing: 0) {
                    header
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
}

extension MasonryGrid where Header == EmptyView {
    init(
        items: [Item],
        aspectRatio: @escaping (Item) -> Double,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.init(items: items, aspectRatio: aspectRatio, header: { EmptyView() }, content: content)
    }
}

/// A collection's name shown at the top of a `MasonryGrid`'s scroll content on macOS, so it
/// scrolls away as the user scrolls into the cards (the pushed destination's inline title band is
/// hidden — see `LibraryView`). Renders nothing on iOS, where the name is the native navigation
/// title.
struct ScrollingCollectionTitle: View {
    let title: String

    var body: some View {
        #if os(macOS)
        Text(title)
            .font(.largeTitle)
            .fontWeight(.bold)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
        #else
        EmptyView()
        #endif
    }
}
