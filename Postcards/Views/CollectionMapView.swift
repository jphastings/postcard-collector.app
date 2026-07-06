import CoreLocation
import MapKit
import SwiftUI

/// The collection view's "map mode" (see `CollectionModeSwitcher`): one pin per distinct
/// coordinate, framed so all of them are visible on first appearance. Cards at exactly the
/// same coordinate share a pin (see `MapPinGrouping`).
///
/// Interaction: a single-card pin opens its card in the detail pane directly on click/tap —
/// same `selection` binding as tapping a grid cell. A multi-card pin never opens anything
/// directly; it raises a popover listing each card's name, and tapping a name opens that
/// card. On macOS the popover also shows on hover (for single pins too, as a preview of the
/// name), and stays up while the pointer remains over the pin or any of the name rows.
struct CollectionMapView: View {
    let entries: [MapCardEntry]
    @Binding var selection: CardReference?

    @State private var cameraPosition: MapCameraPosition
    /// The group whose popover is open by click/tap (macOS hover shows popovers without
    /// touching this). At most one at a time.
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
                        onToggle: { toggle(group) },
                        onOpen: { reference in
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

    private func toggle(_ group: MapPinGroup<MapCardEntry>) {
        withAnimation(.easeInOut(duration: 0.2)) {
            openGroupID = (openGroupID == group.id) ? nil : group.id
        }
    }
}

/// One pin's content: the pin glyph (badged with a count when several cards share the
/// coordinate) plus, when open/hovered, a name popover anchored above it.
private struct MapPinAnnotation: View {
    let group: MapPinGroup<MapCardEntry>
    let isOpen: Bool
    let onToggle: () -> Void
    let onOpen: (CardReference) -> Void

    @State private var isHovered = false
    @State private var hoverHideTask: Task<Void, Never>?

    private var isSingle: Bool { group.elements.count == 1 }
    private var showsPopover: Bool { isOpen || isHovered }

    var body: some View {
        VStack(spacing: 6) {
            if showsPopover {
                popover
                    .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
            }
            pinButton
        }
        // One contiguous hover region covering pin, popover, AND the gap between them, so
        // moving the pointer from the pin up into the name rows never counts as an exit.
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { hovering in
            hoverHideTask?.cancel()
            if hovering {
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = true }
            } else {
                // Short grace before hiding: pointer wobbles across the popover's rounded
                // corners (momentarily outside the shape) mustn't dismiss the names.
                hoverHideTask = Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.15)) { isHovered = false }
                }
            }
        }
        #endif
    }

    private var pinButton: some View {
        Button {
            if isSingle {
                // Single card: the pin IS the card — open it directly, like a grid cell.
                onOpen(group.elements[0].reference)
            } else {
                onToggle()
            }
        } label: {
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
                        onOpen(entry.reference)
                    } label: {
                        Text(entry.summary.name)
                            .font(.callout)
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
