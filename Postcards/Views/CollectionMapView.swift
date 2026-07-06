import CoreLocation
import MapKit
import SwiftUI

/// The collection view's "map mode" (see `CollectionModeSwitcher`): one pin per distinct
/// coordinate, framed so all of them are visible on first appearance. Cards at exactly the
/// same coordinate share a pin (see `MapPinGrouping`).
///
/// Interaction: clicking a pin ALWAYS navigates — a single-card pin opens its card in the
/// detail pane (same `selection` binding as tapping a grid cell); a multi-card pin rotates
/// through its cards on successive clicks (see `MapPinRotation`) while raising a popover
/// naming them all, with a checkmark on the open one. Tapping a name in the popover opens
/// that card directly. On macOS popovers also show on hover (single pins too, as a name
/// preview) and stay up while the pointer remains over the pin or any of the name rows.
struct CollectionMapView: View {
    let entries: [MapCardEntry]
    @Binding var selection: CardReference?

    @State private var cameraPosition: MapCameraPosition
    /// The group whose popover is held open by click/tap (macOS hover shows popovers
    /// without touching this). At most one at a time.
    @State private var openGroupID: String?

    init(entries: [MapCardEntry], selection: Binding<CardReference?>) {
        self.entries = entries
        self._selection = selection
        let coordinates = entries.compactMap(\.summary.coordinate)
        if let region = MapRegionFitting.region(for: coordinates) {
            _cameraPosition = State(initialValue: .region(region))
        } else {
            _cameraPosition = State(initialValue: .automatic)
        }
    }

    private var groups: [MapPinGroup<MapCardEntry>] {
        MapPinGrouping.groups(of: entries) { $0.summary.coordinate }
    }

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(groups) { group in
                // Qualified: `Models.swift` already declares its own `Annotation` (for
                // postcard transcriptions), which shadows MapKit's SwiftUI `Annotation`
                // content type in this module. The label builder is empty on purpose —
                // always-visible names under every pin were clutter; names live in the
                // popover instead.
                MapKit.Annotation(coordinate: group.coordinate, anchor: .bottom) {
                    MapPinAnnotation(
                        group: group,
                        isOpen: openGroupID == group.id,
                        selection: selection,
                        onPinClick: { pinClicked(group) },
                        onNameClick: { reference in
                            selection = reference
                            withAnimation(.easeInOut(duration: 0.2)) { openGroupID = nil }
                        }
                    )
                } label: {
                    EmptyView()
                }
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        // Lets tapping empty water/land close whatever popover is open — Map's own gesture
        // handling for panning/zooming is a drag/magnify, not a tap, so this doesn't
        // interfere with it, and the pin buttons underneath consume their own taps first.
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { openGroupID = nil }
        }
    }

    /// A pin click always navigates: to the single card, or the next co-located card in
    /// rotation. Multi-card pins also hold their name popover open so the rotation is
    /// legible (which card is open gets a checkmark) — on iOS this is the only way the
    /// list shows at all, there being no hover.
    private func pinClicked(_ group: MapPinGroup<MapCardEntry>) {
        if let next = MapPinRotation.next(in: group.elements.map(\.reference), after: selection) {
            selection = next
        }
        if group.elements.count > 1 {
            withAnimation(.easeInOut(duration: 0.2)) { openGroupID = group.id }
        }
    }
}

/// One pin's content: the pin glyph (badged with a count when several cards share the
/// coordinate) plus a column of names growing UPWARD from just above it.
///
/// Anchor invariant: the annotation reserves the popover's exact space permanently via a
/// `.hidden()` copy of the popover itself (self-measuring — no magic sizes, correct under
/// Dynamic Type and any number of names), so the annotation's frame is identical whether
/// or not the names are showing and Map's `.bottom` anchor — the pin — never moves. The
/// REAL popover is only mounted while showing, as a bottom-aligned overlay on that slot:
/// the row nearest the pin stays adjacent and the list extends up the screen. Keeping the
/// visible copy conditionally mounted (rather than a permanently-mounted, opacity-hidden
/// layer) also gives Map's annotation bridging nothing stale to composite.
private struct MapPinAnnotation: View {
    let group: MapPinGroup<MapCardEntry>
    let isOpen: Bool
    let selection: CardReference?
    let onPinClick: () -> Void
    let onNameClick: (CardReference) -> Void

    @State private var isHovered = false
    @State private var hoverHideTask: Task<Void, Never>?

    private var isSingle: Bool { group.elements.count == 1 }
    private var showsPopover: Bool { isOpen || isHovered }

    var body: some View {
        VStack(spacing: 6) {
            // The reserved slot: identical geometry to the real popover, never rendered,
            // never hit-testable, invisible to accessibility — map gestures pass through.
            popover
                .hidden()
                .overlay(alignment: .bottom) {
                    if showsPopover {
                        hoverTracked(popover)
                            .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                    }
                }
            hoverTracked(pinButton)
        }
        .animation(.easeInOut(duration: 0.15), value: showsPopover)
        // No contentShape here: the container's empty region (the reserved slot while
        // hidden, and the 6pt gap) must stay transparent to map gestures. Hover
        // continuity across the pin→names gap is handled by the grace timer below.
    }

    /// macOS: entering either the pin or the (visible) popover keeps the names up; the
    /// hide is delayed so the pointer can cross the small gap between them — the names
    /// remain until neither is hovered. Other platforms: untouched.
    private func hoverTracked(_ view: some View) -> some View {
        #if os(macOS)
        return view.onHover { hovering in
            hoverHideTask?.cancel()
            if hovering {
                isHovered = true
            } else {
                hoverHideTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    isHovered = false
                }
            }
        }
        #else
        return view
        #endif
    }

    private var pinButton: some View {
        Button(action: onPinClick) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .background(Circle().fill(.white).padding(3))
                .overlay(alignment: .topTrailing) {
                    if !isSingle {
                        Text("\(group.elements.count)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(.blue))
                            .offset(x: 7, y: -7)
                    }
                }
        }
        .buttonStyle(.plain)
        // Stable machine-facing handle for UI tests, same convention as the grid cells:
        // a single-card pin is addressable by its card's name.
        .accessibilityIdentifier(isSingle ? group.elements[0].summary.name : group.elements.map(\.summary.name).joined(separator: "+"))
        .accessibilityLabel(
            isSingle
                ? group.elements[0].summary.name
                : "\(group.elements.count) postcards: \(group.elements.map(\.summary.name).joined(separator: ", "))"
        )
    }

    @ViewBuilder
    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isSingle {
                Text(group.elements[0].summary.name)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            } else {
                ForEach(group.elements) { entry in
                    Button {
                        onNameClick(entry.reference)
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.summary.name)
                                .font(.callout)
                            Spacer(minLength: 0)
                            // Marks where the pin-click rotation currently sits. Always
                            // mounted (hidden by opacity) so the row's width — and with
                            // it the reserved slot and annotation frame — doesn't change
                            // as the checkmark hops between rows.
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .opacity(entry.reference == selection ? 1 : 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(entry.summary.name)
                    if entry.id != group.elements.last?.id {
                        Divider()
                    }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 6, y: 3)
        .fixedSize()
    }
}
