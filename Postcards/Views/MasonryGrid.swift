import SwiftUI

/// A masonry (Pinterest-style) grid: SwiftUI has no built-in one, so this is the standard
/// robust construction — a ScrollView holding an HStack of N equal-width LazyVStack
/// columns, with items dealt to the currently-shortest column by their KNOWN aspect ratios
/// (see `MasonryLayout`; no image decode is needed for layout). Postcards vary a lot in
/// aspect ratio, so this wastes far less space than a uniform grid.
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
            let columnCount = MasonryLayout.columnCount(
                forAvailableWidth: proxy.size.width - spacing * 2,
                spacing: spacing
            )
            let columns = MasonryLayout.columns(of: items, count: columnCount, aspectRatio: aspectRatio)

            ScrollView {
                VStack(spacing: 0) {
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
                    footer
                }
            }
            // The header (e.g. a collection's name and Back) stays put while the cards scroll
            // beneath it, so the way back is always in reach.
            .modifier(PinnedHeader(header: header))
        }
    }
}

/// Pins `header` above a scroll view's content: a `safeAreaBar` where available, so the
/// content scrolls under it behind the system scroll-edge effect, as it does under toolbars.
private struct PinnedHeader<Header: View>: ViewModifier {
    let header: Header

    func body(content: Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            // Asked for explicitly: the window's hidden toolbar background otherwise leaves the
            // edge hard, with cards showing straight through behind the header.
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) { header }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { header.background(.bar) }
        }
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
