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
        // A single connected control (not two loose icons) so grid and map read as one
        // mutually-exclusive either-or, with the selected segment highlighted. Only the map
        // segment is gated on the collection having locations; grid is always available.
        HStack(spacing: 0) {
            ForEach(CollectionViewMode.allCases) { candidate in
                segment(candidate)
                if candidate != CollectionViewMode.allCases.last {
                    Divider().frame(height: 16)
                }
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
        .accessibilityElement(children: .contain)
        // Stable machine-facing handle for UI tests.
        .accessibilityIdentifier("CollectionModeSwitcher")
    }

    private func segment(_ candidate: CollectionViewMode) -> some View {
        let selected = mode == candidate
        let disabled = candidate == .map && !isEnabled
        return Image(systemName: candidate.systemImage)
            .imageScale(.medium)
            .frame(width: 34, height: 22)
            .foregroundStyle(disabled ? AnyShapeStyle(.tertiary)
                : selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
            // A tap gesture, not a `Button`: a `Button` nested in this titlebar toolbar item loses
            // its first click to AppKit's tracking loop (needs a double-click); a tap gesture
            // registers on the first click. See CLAUDE.md and the map pins.
            .onTapGesture { if !disabled { mode = candidate } }
            .accessibilityLabel(candidate.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(disabled ? "No postcards in this collection have a location" : "")
    }
}
