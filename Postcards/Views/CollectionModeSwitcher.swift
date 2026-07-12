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
/// the grid/map content, which scrolls beneath it. Being part of the pane's own view tree
/// rather than the shared window toolbar, its position no longer depends on the detail
/// column's contribution at all — so on macOS, `LibraryView`'s placeholder-mirroring doc
/// comment is now historical rather than load-bearing (the placeholder is still kept
/// there because iOS still needs it).
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
        overlay(alignment: .topTrailing) {
            // Sized/styled to read like the window-toolbar glass buttons (the detail pane's
            // (i)): icon glyphs on one small floating capsule of glass.
            CollectionModeSwitcher(mode: mode, isEnabled: isEnabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .floatingGlassBackground(in: Capsule())
                .padding(12)
        }
        #else
        self
        #endif
    }
}
