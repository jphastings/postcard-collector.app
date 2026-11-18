import SwiftUI

/// A masonry (Pinterest-style) grid: items are dealt into N equal-width columns, each to the
/// currently-shortest one, by their KNOWN aspect ratios (see `MasonryLayout`). Postcards vary a
/// lot in aspect ratio, so this wastes far less space than a uniform grid.
///
/// Every frame is computed up front, so the scroll content has its exact height from the start
/// and only cells near the visible area are created, each at its precomputed place. Lazy stacks
/// can't do this: they estimate the heights of cells they've discarded, so scrolling back up made
/// cards jump and could leave a screen of slack above the first row.
///
/// Reading order is column-balanced rather than strict rows — items enter in the given
/// order, so it still reads roughly left-to-right, top-to-bottom.
struct MasonryGrid<Item: Identifiable, Content: View, Header: View, Footer: View>: View {
    let items: [Item]
    let aspectRatio: (Item) -> Double
    let header: Header
    /// Full width, after the last item.
    let footer: Footer
    @ViewBuilder let content: (Item) -> Content

    private let spacing: CGFloat = 16
    /// The content's vertical span worth rendering; `nil` until the grid first reports its
    /// scroll position.
    @State private var renderSpan: ClosedRange<Double>?

    init(
        items: [Item],
        aspectRatio: @escaping (Item) -> Double,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.aspectRatio = aspectRatio
        self.header = header()
        self.footer = footer()
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - spacing * 2
            let placement = MasonryLayout.placement(
                of: items,
                width: width,
                columnCount: MasonryLayout.columnCount(forAvailableWidth: width, spacing: spacing),
                spacing: spacing,
                aspectRatio: aspectRatio
            )
            let viewportHeight = proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            let span = renderSpan ?? MasonryLayout.renderSpan(scrollOffset: 0, viewportHeight: viewportHeight)

            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        ForEach(rendered(placement, in: span)) { cell in
                            content(cell.item)
                                .frame(width: cell.frame.width, height: cell.frame.height)
                                .offset(x: cell.frame.minX, y: cell.frame.minY)
                        }
                    }
                    .frame(width: max(width, 0), height: placement.contentHeight, alignment: .topLeading)
                    // Reads where the content sits in the scroll view, which depends only on the
                    // scroll position: the frame above is fixed by `placement`, whatever renders.
                    .onGeometryChange(for: ClosedRange<Double>.self) { content in
                        MasonryLayout.renderSpan(
                            scrollOffset: -content.frame(in: .scrollView).minY,
                            viewportHeight: viewportHeight
                        )
                    } action: { renderSpan = $0 }
                    .padding(spacing)
                    footer
                }
            }
            // The header (e.g. a collection's name and Back) stays put while the cards scroll
            // beneath it, so the way back is always in reach.
            .modifier(PinnedHeader(header: header))
        }
    }

    private func rendered(_ placement: MasonryLayout.Placement, in span: ClosedRange<Double>) -> [PlacedItem] {
        zip(items, placement.frames)
            .filter { span.overlaps(Double($0.1.minY)...Double($0.1.maxY)) }
            .map { PlacedItem(item: $0.0, frame: $0.1) }
    }

    private struct PlacedItem: Identifiable {
        let item: Item
        let frame: CGRect
        var id: Item.ID { item.id }
    }
}

/// Pins `header` above a scroll view's content: a `safeAreaBar` where available, so the
/// content scrolls under it behind the system scroll-edge effect, as it does under toolbars.
private struct PinnedHeader<Header: View>: ViewModifier {
    let header: Header

    func body(content: Content) -> some View {
        #if os(iOS)
        // iOS has no header to pin (the name is the navigation title), and a safeAreaBar
        // holding nothing there still reserved about a screen's height above the cards.
        content
        #else
        if #available(macOS 26, *) {
            // Asked for explicitly: the window's hidden toolbar background otherwise leaves the
            // edge hard, with cards showing straight through behind the header.
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) { header }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { header.background(.bar) }
        }
        #endif
    }
}

extension MasonryGrid where Footer == EmptyView {
    init(
        items: [Item],
        aspectRatio: @escaping (Item) -> Double,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.init(items: items, aspectRatio: aspectRatio, header: header, footer: { EmptyView() }, content: content)
    }
}

extension MasonryGrid where Header == EmptyView, Footer == EmptyView {
    init(
        items: [Item],
        aspectRatio: @escaping (Item) -> Double,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.init(items: items, aspectRatio: aspectRatio, header: { EmptyView() }, content: content)
    }
}

/// A collection's name, with Back beside it, pinned at the top of a `MasonryGrid` on macOS (the
/// pushed destination's inline title band is hidden — see `LibraryView`). Renders nothing on iOS, where the name is the native navigation
/// title.
struct CollectionTitle: View {
    let title: String

    #if os(macOS)
    /// Pops the sidebar's pushed browser: this title only ever heads a pushed destination.
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        HStack(spacing: 6) {
            // Back sits beside the name rather than in the toolbar, so the sidebar's toolbar
            // doesn't set how narrow the column can get.
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.backward")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")
            .accessibilityLabel("Back")
            .accessibilityIdentifier("SidebarBack")
            Text(title)
                .font(.largeTitle)
                .fontWeight(.bold)
                .lineLimit(1)
        }
        .preference(key: ShowsInlineBackKey.self, value: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        #else
        EmptyView()
        #endif
    }
}

#if os(macOS)
/// Whether a pushed browser is showing `CollectionTitle`'s Back; when it isn't (map,
/// loading, an error), the browser floats its own.
struct ShowsInlineBackKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
#endif
