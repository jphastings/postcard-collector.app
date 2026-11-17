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
        // The grid min is held wide enough that the window toolbar (traffic lights + sidebar
        // toggle + Add + the grid/map switcher) always fits without collapsing items into the
        // ">>" overflow menu. Back isn't in it: it sits beside the collection's name instead.
        case .grid: return Bounds(min: 270, ideal: 340, max: 400)
        // The map can be dragged narrower than the grid can be wide, but opens wider.
        case .map: return Bounds(min: 300, ideal: 500, max: 700)
        }
    }
}

/// What the window does when the sidebar and the postcard pane stop fitting side by side,
/// following Finder/Mail: narrowing the window collapses the sidebar (and widening it again
/// brings back a sidebar that was collapsed that way); anything else that needs more room —
/// showing the sidebar, or switching it to the wider map — grows the window instead. Without
/// this, SwiftUI keeps the sidebar at its minimum and slides it off the window's left edge.
enum SidebarFit {
    /// The postcard pane's narrowest useful width.
    static let detailMinWidth: CGFloat = 320
    /// The floating sidebar's own insets and the split between the panes.
    static let chrome: CGFloat = 24

    /// `detailExtra` is anything the postcard pane carries beside the card, i.e. an open
    /// inspector.
    static func requiredWidth(for mode: CollectionViewMode, detailExtra: CGFloat = 0) -> CGFloat {
        SidebarWidths.bounds(for: mode).min + detailMinWidth + detailExtra + chrome
    }

    enum Action: Equatable {
        case none
        case collapseSidebar
        case restoreSidebar
        case growWindow(by: CGFloat)
    }

    /// The window was resized from `oldWidth` to `newWidth`.
    static func afterResize(
        from oldWidth: CGFloat, to newWidth: CGFloat, mode: CollectionViewMode, detailExtra: CGFloat = 0,
        sidebarShown: Bool, autoCollapsed: Bool
    ) -> Action {
        let required = requiredWidth(for: mode, detailExtra: detailExtra)
        if newWidth < oldWidth, newWidth < required, sidebarShown { return .collapseSidebar }
        if newWidth > oldWidth, newWidth >= required, !sidebarShown, autoCollapsed { return .restoreSidebar }
        return .none
    }

    /// The sidebar was shown, its mode changed, or the inspector opened, in a window `width` wide.
    static func afterSidebarChange(
        width: CGFloat, mode: CollectionViewMode, detailExtra: CGFloat = 0, sidebarShown: Bool
    ) -> Action {
        let shortfall = requiredWidth(for: mode, detailExtra: detailExtra) - width
        return sidebarShown && shortfall > 0 ? .growWindow(by: shortfall) : .none
    }
}
