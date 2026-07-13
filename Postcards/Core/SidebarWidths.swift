import CoreGraphics

/// The two ways a collection's cards can be browsed: the thumbnail grid, or
/// `CollectionMapView`'s pins. Declared here (not alongside `CollectionModeSwitcher`, which
/// uses it) so `SidebarWidths` below — and its unit test — can reference it: `PostcardsTests`
/// compiles `Postcards/Core` directly rather than importing the app module, and this type is
/// pure data with no view dependencies, so `Core` is where it belongs anyway.
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

/// The sidebar column's `.navigationSplitViewColumnWidth` bounds, as a pure function of the
/// collection browser's current view mode — `LibraryView` reads this to size the column
/// itself. The sidebar's level-1 collections list has no map mode of its own, so it shares the
/// narrower `.grid` bounds; only entering `.map` mode inside a browsed collection widens the
/// column, giving its pins room to breathe.
enum SidebarWidths {
    struct Bounds: Equatable {
        let min: CGFloat
        let ideal: CGFloat
        let max: CGFloat
    }

    static func bounds(for mode: CollectionViewMode) -> Bounds {
        switch mode {
        case .grid: return Bounds(min: 230, ideal: 300, max: 400)
        case .map: return Bounds(min: 400, ideal: 500, max: 700)
        }
    }
}
