import SwiftUI

/// Toggles the collection browser (`CollectionGridView`/`SinglePostcardsGridView`/
/// `AllCollectionsView`) between grid and map mode (see `CollectionViewMode`, declared in
/// `Postcards/Core/SidebarWidths.swift`).
///
/// This is a single `ToolbarItem`, attached ONCE by `LibraryView`'s `CollectionBrowser`
/// destination wrapper on both platforms — not per-pane, and not an overlay. That wrapper is
/// the sidebar column's own `NavigationStack` push destination, so its toolbar section is the
/// sidebar's *stable* toolbar section: in the titlebar by construction, clickable by
/// construction. This replaces an earlier design where the switcher's placement drifted
/// out three separate times as other `NavigationSplitView` columns' own toolbar contributions
/// changed (it used to be a per-column toolbar item whose position was an emergent artifact of
/// the split view's per-column toolbar merge), and, on macOS, a subsequent in-pane `.overlay`
/// workaround that bled into the titlebar band and needed a `.onTapGesture` hack because a real
/// `Button` there lost its first click to AppKit's own titlebar hit-testing. Neither problem
/// exists once the switcher is a real toolbar item on a column that never shares a toolbar
/// section with anything else — so both platforms use a single, plain `Button` here.
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
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? "" : "No postcards in this collection have a location")
        // `.contain` gives the HStack itself a real, queryable accessibility element/frame —
        // needed for `.accessibilityIdentifier` below to resolve to something in a UI test —
        // while still exposing the "Grid"/"Map" buttons as their own elements underneath it
        // (unlike `.combine`, which would merge them into one and make VoiceOver unable to
        // select a mode directly).
        .accessibilityElement(children: .contain)
        // Stable machine-facing handle for UI tests.
        .accessibilityIdentifier("CollectionModeSwitcher")
    }
}
