import SwiftUI

/// The two ways a collection's cards can be browsed: the existing thumbnail grid, or
/// `CollectionMapView`'s pins.
enum CollectionViewMode: String, CaseIterable, Identifiable {
    case grid
    case map

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .map: return "map"
        }
    }

    var label: String {
        switch self {
        case .grid: return "Grid"
        case .map: return "Map"
        }
    }
}

/// Toggles `CollectionGridView`/`SinglePostcardsGridView` between grid and map mode.
///
/// iOS: placed at `.primaryAction` in the content column's own toolbar, immediately left of
/// the detail column's "Info" button (SwiftUI merges a `NavigationSplitView`'s per-column
/// `.primaryAction` toolbar items in column order). That merge is sensitive to what the
/// DETAIL column's toolbar contributes: with nothing selected, `LibraryView`'s
/// "Select a Postcard" placeholder mirrors `CardDetailView`'s own at-rest (unzoomed) iOS
/// toolbar contribution — an unconditional, disabled (i) — precisely so the content column's
/// own toolbar items never have to shift depending on selection; see that placeholder's doc
/// comment.
///
/// macOS: deliberately NOT a toolbar item at all, after this control drifted out of place
/// three times as other columns' toolbar contributions changed (most recently in v0.5.12,
/// when the detail column's own macOS toolbar contribution went from "Reset Zoom while
/// zoomed" to empty at rest, which was enough to shift this control to the trailing edge
/// next to the search field). Chasing the detail column's toolbar shape has proven too
/// fragile to keep fixing, so on macOS this is instead rendered via
/// `View.collectionModeSwitcherOverlay(mode:isEnabled:)` below — a plain
/// `.overlay(alignment: .topTrailing)` INSIDE the content pane itself, styled as a floating
/// glass chip (reusing `BottomSearchBar`'s `floatingGlassBackground(in:)`) that floats above
/// the grid/map content, which scrolls beneath it, and is vertically centred in the
/// transparent window-toolbar band so it reads as one of the toolbar's own glass buttons
/// (see that function's doc comment for how). Being part of the pane's own view tree rather
/// than the shared window toolbar, its position no longer depends on the detail column's
/// contribution at all — so on macOS, `LibraryView`'s placeholder-mirroring doc comment is
/// now historical rather than load-bearing (the placeholder is still kept there because iOS
/// still needs it).
///
/// Deliberately plain `Button`s rather than a `Picker(.segmented)`: on iOS 26 a segmented
/// control has its own Liquid Glass material, and stacking that inside the toolbar item's
/// own glass background rendered as two visible glass layers. Plain buttons carry no
/// Material of their own, so — sharing this single glass surface (toolbar item on iOS, the
/// overlay chip on macOS) — they pick up exactly one glass background between them, with the
/// selected mode shown via a filled glyph.
struct CollectionModeSwitcher: View {
    @Binding var mode: CollectionViewMode
    var isEnabled: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(CollectionViewMode.allCases) { candidate in
                Button(candidate.label, systemImage: candidate.systemImage) {
                    mode = candidate
                }
                .symbolVariant(mode == candidate ? .fill : .none)
                .foregroundStyle(mode == candidate ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        // Icon-only + borderless: a toolbar applies both automatically, but this control
        // also renders inside the macOS in-pane overlay, where the defaults would show the
        // buttons' text with bordered push-button chrome.
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "" : "No postcards in this collection have a location")
        // `.contain` (rather than the default) gives the HStack itself a real, queryable
        // accessibility element/frame — needed for `.accessibilityIdentifier` below to
        // resolve to something in a UI test — while still exposing the "Grid"/"Map" buttons
        // as their own elements underneath it (unlike `.combine`, which would merge them
        // into one and make VoiceOver unable to select a mode directly).
        .accessibilityElement(children: .contain)
        // Stable machine-facing handle for UI tests (e.g. asserting this stays inside the
        // content pane's bounds on macOS) — see `ModeSwitcherPlacementUITests`.
        .accessibilityIdentifier("CollectionModeSwitcher")
    }
}

extension View {
    /// macOS-only: floats `CollectionModeSwitcher` as a glass chip overlay INSIDE the
    /// content pane (top-trailing), rather than a toolbar item — see `CollectionModeSwitcher`'s
    /// doc comment for why the toolbar placement kept breaking. A no-op on iOS, which keeps
    /// the toolbar placement added by each call site's own `.toolbar`.
    ///
    /// Applied to the pane's whole `Group` (all of grid/map/loading/error/empty states), so
    /// the chip stays visible and correctly positioned no matter which of those is showing;
    /// it never collides with `BottomSearchBar`/its suggestions list, since those anchor to
    /// the opposite (bottom) edge.
    @ViewBuilder
    func collectionModeSwitcherOverlay(mode: Binding<CollectionViewMode>, isEnabled: Bool) -> some View {
        #if os(macOS)
        modifier(CollectionModeSwitcherOverlayModifier(mode: mode, isEnabled: isEnabled))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// Positions the chip so it appears to sit IN the transparent window-toolbar band above the
/// content pane (vertically centred, like the toolbar's own glass buttons — e.g. the detail
/// pane's (i)) while remaining structurally an overlay owned by the content pane itself.
///
/// A plain `.overlay(alignment: .topTrailing)` on the pane renders its content BELOW the
/// pane's top safe-area inset by default — that inset is exactly the toolbar band's height,
/// since the pane's own content (the grid) already extends full-bleed behind the transparent
/// bar and scrolls under it. Two things are needed to lift the chip into that band instead:
///
/// 1. Measure the band's height. A `GeometryReader` placed as the overlay's content, left
///    WITHIN the safe area (i.e. not itself `.ignoresSafeArea(_:)`), still reports the
///    band's height via `proxy.safeAreaInsets.top` even though its own layout is confined
///    below the bar — the same technique `CardDetailView.body` uses (see its doc comment)
///    to read surrounding chrome insets before a nested view bleeds past them.
/// 2. Let the chip itself bleed upward. `.ignoresSafeArea(edges: .top)` is applied to the
///    chip's own frame (not to the measuring `GeometryReader` — doing it there would zero
///    out the very inset step 1 just read), which lets `.frame(maxWidth: .infinity,
///    maxHeight: .infinity, alignment: .topTrailing)` expand past the safe boundary so
///    `.topTrailing` resolves against the pane's true top-trailing corner, inside the band,
///    rather than below it.
///
/// With the band height known, the chip is padded from the top by `(band - chipHeight) / 2`
/// to centre it vertically in the band, keeping the original ~12pt trailing padding. The
/// chip's own height is measured (not hard-coded) via a second `GeometryReader`/
/// `PreferenceKey` pair, mirroring how `BottomSearchBar` measures its field's height —
/// Dynamic Type or a future icon size change could otherwise throw the centring off. If the
/// band is 0 (no toolbar — shouldn't happen in this app, but guarded anyway) or thinner than
/// the chip, this falls back to the original below-the-bar placement (12pt clear of the top).
private struct CollectionModeSwitcherOverlayModifier: ViewModifier {
    @Binding var mode: CollectionViewMode
    var isEnabled: Bool

    @State private var chipHeight: CGFloat = 36

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            GeometryReader { proxy in
                let bandHeight = proxy.safeAreaInsets.top
                chip
                    .padding(.top, bandHeight > 0 ? max((bandHeight - chipHeight) / 2, 0) : 12)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .ignoresSafeArea(edges: .top)
            }
        }
    }

    // Sized/styled to read like the window-toolbar glass buttons (the detail pane's (i)):
    // icon glyphs on one small floating capsule of glass.
    private var chip: some View {
        CollectionModeSwitcher(mode: $mode, isEnabled: isEnabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .floatingGlassBackground(in: Capsule())
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ModeSwitcherChipHeightPreferenceKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(ModeSwitcherChipHeightPreferenceKey.self) { chipHeight = $0 }
    }
}

private struct ModeSwitcherChipHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 36
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
#endif
