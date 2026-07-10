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

/// Toggles `CollectionGridView`/`SinglePostcardsGridView` between grid and map mode —
/// placed in the toolbar immediately left of the detail column's "Info" button (SwiftUI
/// merges a `NavigationSplitView`'s per-column `.primaryAction` toolbar items in column
/// order, so putting this at `.primaryAction` in the content column lands it right before
/// the detail column's own `.primaryAction` item).
///
/// That merge is sensitive to what the DETAIL column's toolbar contributes: with nothing
/// selected, `LibraryView`'s "Select a Postcard" placeholder used to contribute no toolbar
/// items at all, and the merge would then drag this control to the trailing edge next to
/// the search field instead of sitting beside the (now absent) Info button — visibly
/// detached from the content pane it controls, and inconsistent with every other selection
/// state. An in-pane `safeAreaInset` header was tried and rejected: it isn't the native
/// toolbar's liquid-glass material, and it stops the grid/map reaching the very top of the
/// window. The fix that keeps a real toolbar item is instead on the DETAIL side: the
/// placeholder now carries a disabled stand-in for the Info button (see `LibraryView`), so
/// the content column's own toolbar items never have to shift regardless of selection.
///
/// Deliberately plain `Button`s rather than a `Picker(.segmented)`: on iOS 26 a segmented
/// control has its own Liquid Glass material, and stacking that inside the toolbar item's
/// own glass background rendered as two visible glass layers. Plain buttons carry no
/// Material of their own, so — sharing this single toolbar slot — they pick up exactly one
/// glass background between them, with the selected mode shown via a filled glyph.
struct CollectionModeSwitcher: View {
    @Binding var mode: CollectionViewMode
    var isEnabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CollectionViewMode.allCases) { candidate in
                Button(candidate.label, systemImage: candidate.systemImage) {
                    mode = candidate
                }
                .symbolVariant(mode == candidate ? .fill : .none)
                .foregroundStyle(mode == candidate ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "" : "No postcards in this collection have a location")
    }
}
