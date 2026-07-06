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

/// A compact segmented control toggling `CollectionGridView`/`SinglePostcardsGridView`
/// between grid and map mode — placed in the toolbar immediately left of the detail
/// column's "Info" button (SwiftUI merges a `NavigationSplitView`'s per-column
/// `.primaryAction` toolbar items in column order, so putting this at `.primaryAction` in
/// the content column lands it right before the detail column's own `.primaryAction` item).
struct CollectionModeSwitcher: View {
    @Binding var mode: CollectionViewMode
    var isEnabled: Bool

    var body: some View {
        Picker("View Mode", selection: $mode) {
            ForEach(CollectionViewMode.allCases) { candidate in
                Image(systemName: candidate.systemImage)
                    .accessibilityLabel(candidate.label)
                    .tag(candidate)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(!isEnabled)
        .accessibilityLabel("View Mode")
        .accessibilityHint(isEnabled ? "" : "No postcards in this collection have a location")
    }
}
