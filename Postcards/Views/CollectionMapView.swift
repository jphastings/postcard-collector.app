import CoreLocation
import MapKit
import SwiftUI

/// The collection view's "map mode" (see `CollectionModeSwitcher`): pins framed so all of
/// them are visible on first appearance, clustered by what would actually overlap ON
/// SCREEN at the current camera (see `MapPinClustering`) — zooming in splits a merged pin
/// back into its parts, zooming out merges neighbours, and exact-coordinate duplicates
/// never split.
///
/// Interaction: clicking a pin ALWAYS navigates — a single-card pin opens its card in the
/// detail pane (same `selection` binding as tapping a grid cell); a multi-card pin rotates
/// through its cards on successive clicks (see `MapPinRotation`) while raising a popover
/// naming them all, with an accent-tinted row for the open one. Tapping a name in the
/// popover opens that card directly. On macOS popovers also show on hover (single pins too,
/// as a name preview) and stay up while the pointer remains over the pin or any of the name
/// rows.
///
/// Cluster split/merge animation: every located card owns exactly ONE annotation, keyed by
/// its OWN card id — that identity never changes, so SwiftUI never tears one down and
/// creates another as clustering changes (which is what caused pins to "pop" instead of
/// glide). Each annotation sits at its card's true coordinate always (so MapKit's own
/// per-frame projection keeps it correctly placed through ordinary panning/zooming with no
/// help needed), and carries an additional `.offset()` — computed in SCREEN POINTS from that
/// card's true position to its current cluster's shared centroid — that visually nudges it
/// on top of its cluster-mates. `.offset` is a plain, reliable SwiftUI animatable (unlike
/// MapKit's own annotation-coordinate bridging, which does not reliably interpolate), so an
/// offset change makes every affected pin glide smoothly between "at the shared centroid"
/// and "at its own coordinate" — split and merge are the same animation, run in opposite
/// directions.
///
/// Timing: offsets are screen-point vectors, only meaningful at the camera they were
/// projected under — so reclustering waits for the gesture to FULLY settle
/// (`.onMapCameraChange(frequency: .onEnd)`) rather than firing mid-gesture. During a
/// zoom/pan the existing offsets stay frozen (MapKit scales the whole annotation layer, so
/// clustered pins ride along still visually grouped, merely at slightly stale spacings);
/// the moment the camera stops, clusters AND offsets are recomputed against the settled
/// projections in one update, and each pin glides — at a now-fixed camera — from wherever
/// the stale offset left it to its correct new position. A second gesture landing
/// mid-glide simply retargets: the animation is value-scoped on `pinOffset` (see
/// `MapPinAnnotation`), so a fresh settle's new offsets smoothly redirect the in-flight
/// motion rather than fighting it.
///
/// Every card in a cluster renders the SAME plain pin glyph (and badge) unconditionally —
/// not just a chosen "representative" — so that when a cluster splits every member's pin is
/// already on screen and simply glides to its own position, rather than popping into
/// existence at the destination once it stops being merged. Because they share one screen
/// point while clustered, this reads as a single pin. Only the cluster's representative (its
/// first member, stable order) additionally carries the interactive layer: the tap target,
/// hover tracking, and the name popover. That interactive content is what invariant (a)
/// below warns mis-composites when merely opacity-hidden inside a MapKit annotation, so
/// non-representative members skip it structurally (no button, no popover) rather than
/// mounting and hiding it.
struct CollectionMapView: View {
    let entries: [MapCardEntry]
    @Binding var selection: CardReference?

    @State private var cameraPosition: MapCameraPosition
    /// The group whose popover is held open by click/tap (macOS hover shows popovers
    /// without touching this). At most one at a time.
    @State private var openGroupID: String?
    /// The current zoom's screen-space clusters; `nil` until the first camera settle
    /// makes projection possible, when exact-coordinate grouping stands in.
    @State private var screenClusters: [MapPinGroup<MapCardEntry>]?
    /// Each located card's current visual nudge (in points) from its own true coordinate to
    /// its cluster's shared centroid — `.zero` for a singleton. Recomputed alongside
    /// `screenClusters`, only at camera settles (see the type's doc comment on timing, and
    /// on why this drives the glide instead of moving each annotation's MapKit coordinate).
    @State private var pinOffsets: [String: CGSize] = [:]

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

    private var locatedEntries: [MapCardEntry] {
        entries.filter { $0.summary.coordinate != nil }
    }

    private var groups: [MapPinGroup<MapCardEntry>] {
        screenClusters ?? MapPinGrouping.groups(of: entries) { $0.summary.coordinate }
    }

    /// Each located card's current cluster, plus whether it's that cluster's representative
    /// (its first member in stable order) — keyed by card id (see `MapPinClustering.membership`).
    private var membership: [String: (group: MapPinGroup<MapCardEntry>, isRepresentative: Bool)] {
        MapPinClustering.membership(of: groups)
    }

    var body: some View {
        GeometryReader { geometry in
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    ForEach(locatedEntries) { entry in
                        if let info = membership[entry.id], let coordinate = entry.summary.coordinate {
                            // Qualified: `Models.swift` already declares its own
                            // `Annotation` (for postcard transcriptions), which shadows
                            // MapKit's SwiftUI `Annotation` content type in this module.
                            // The label builder is empty on purpose — always-visible names
                            // under every pin were clutter; names live in the popover
                            // instead. The coordinate is always this CARD's own true
                            // location (never a centroid) — see the type's doc comment.
                            MapKit.Annotation(coordinate: coordinate, anchor: .bottom) {
                                MapPinAnnotation(
                                    group: info.group,
                                    isRepresentative: info.isRepresentative,
                                    isOpen: openGroupID == info.group.id,
                                    selection: selection,
                                    pinOffset: pinOffsets[entry.id] ?? .zero,
                                    maxPopoverHeight: MapPopoverSizing.maxHeight(forAvailableHeight: geometry.size.height),
                                    onPinClick: { pinClicked(info.group) },
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
                }
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                // Lets tapping empty water/land close whatever popover is open — Map's own
                // gesture handling for panning/zooming is a drag/magnify, not a tap, so this
                // doesn't interfere with it, and the pin buttons underneath consume their
                // own taps first.
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { openGroupID = nil }
                }
                // Re-cluster only when the camera FULLY settles — `.onEnd` IS the settle
                // signal, so no debounce is needed. Mid-gesture the previous offsets stay
                // frozen; recomputing them against in-flight projections would aim every
                // glide at positions that stop being true a frame later (see the type's
                // doc comment on timing). The glide itself comes from the value-scoped
                // offset animation in `MapPinAnnotation`.
                .onMapCameraChange(frequency: .onEnd) { _ in
                    recluster(with: proxy)
                }
                // A new entry set (search narrowing, collection switch) re-clusters
                // immediately — there's no gesture to wait out, and its pins may bear no
                // relation to the previous clusters. Any surviving pins still glide (the
                // value-scoped offset animation doesn't care what triggered the change).
                .onChange(of: entries) { _, _ in
                    recluster(with: proxy)
                }
            }
        }
    }

    private func recluster(with proxy: MapProxy) {
        let located = locatedEntries
        let clusters = MapPinClustering.clusters(of: located) { entry in
            entry.summary.coordinate.flatMap { proxy.convert($0, to: .local) }
        }
        let newGroups: [MapPinGroup<MapCardEntry>] = clusters.compactMap { cluster in
            guard let centroid = MapPinClustering.centroid(of: cluster.compactMap(\.summary.coordinate)) else { return nil }
            return MapPinGroup(coordinate: centroid, elements: cluster)
        }

        screenClusters = newGroups
        pinOffsets = MapPinClustering.offsets(
            of: newGroups,
            projectedElementPoint: { entry in entry.summary.coordinate.flatMap { proxy.convert($0, to: .local) } },
            projectedCentroidPoint: { coordinate in proxy.convert(coordinate, to: .local) }
        )
        // The open popover's group no longer exists once its cards no longer share a
        // pin (a split/merge moved them apart or into a different cluster) — keeping a
        // stale id around would just never match `group.id` again.
        if let openGroupID, !newGroups.contains(where: { $0.id == openGroupID }) {
            self.openGroupID = nil
        }
    }

    /// A pin click always navigates: to the single card, or the next co-located card in
    /// rotation. Multi-card pins also hold their name popover open so the rotation is
    /// legible (the open card gets an accent-tinted row) — on iOS this is the only way the
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

/// One card's annotation content: every card in a cluster renders the plain pin glyph (see
/// the file's doc comment for why), plus — for the cluster's representative only — the
/// interactive tap target, hover tracking, and a column of names growing UPWARD from just
/// above the pin.
///
/// Anchor invariant: the annotation reserves the popover's exact space permanently via a
/// `.hidden()` copy of the popover itself (self-measuring — no magic sizes, correct under
/// Dynamic Type and any number of names), so the annotation's frame is identical whether
/// or not the names are showing and Map's `.bottom` anchor — the pin — never moves. The
/// REAL popover is only mounted while showing, as a bottom-aligned overlay on that slot:
/// the row nearest the pin stays adjacent and the list extends up the screen. Keeping the
/// visible copy conditionally mounted (rather than a permanently-mounted, opacity-hidden
/// layer) also gives Map's annotation bridging nothing stale to composite — invariant (a).
private struct MapPinAnnotation: View {
    let group: MapPinGroup<MapCardEntry>
    let isRepresentative: Bool
    let isOpen: Bool
    let selection: CardReference?
    let pinOffset: CGSize
    let maxPopoverHeight: CGFloat
    let onPinClick: () -> Void
    let onNameClick: (CardReference) -> Void

    @State private var isHovered = false
    @State private var hoverHideTask: Task<Void, Never>?

    private var isSingle: Bool { group.elements.count == 1 }
    private var showsPopover: Bool { isRepresentative && (isOpen || isHovered) }

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
            if isRepresentative {
                hoverTracked(pinButton)
            } else {
                // Not interactive and not separately accessible: this card's pin is
                // visually identical to (and exactly overlapping) the representative's,
                // existing only so ITS OWN position glides correctly when the cluster
                // later splits — see the file's doc comment.
                pinGlyph
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .offset(pinOffset)
        .animation(.easeInOut(duration: 0.15), value: showsPopover)
        // The split/merge glide. Explicit, VALUE-SCOPED animation rather than an ambient
        // `withAnimation` around `CollectionMapView.recluster()`: each annotation's content
        // is hosted by MapKit's own bridging (the same boundary invariant (a) warns about
        // elsewhere in this file), which does not reliably forward an outer transaction
        // into that hosted content — exactly why `showsPopover` above already gets its own
        // explicit `.animation(value:)`. Value scoping also gives clean retargeting: a new
        // settle mid-glide just changes `pinOffset` again and the in-flight motion redirects.
        .animation(.easeInOut(duration: 0.35), value: pinOffset)
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

    /// The pin's glyph and count badge — shared between the representative's interactive
    /// button and the other members' plain, non-interactive copy, so the two render
    /// pixel-identically and overlap seamlessly while clustered.
    private var pinGlyph: some View {
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

    private var pinButton: some View {
        Button(action: onPinClick) {
            pinGlyph
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

    /// A vertical stack of individual name CHIPS — each row its own rounded material
    /// plate (see `MapPinNameChip`), with clear map visible between rows, rather than one
    /// shared translucent container behind them all; individual chips read as native map
    /// callout furniture.
    ///
    /// Capped and scrollable (Feature 3): a pin with many co-located cards grows only up
    /// to `maxPopoverHeight` before the list scrolls, rather than overrunning the map, and
    /// the scroll doesn't rubber-band when everything already fits
    /// (`.scrollBounceBehavior(.basedOnSize)`). The hidden measuring twin renders this
    /// exact same view, so the reserved slot — and the anchor invariant — track the chip
    /// layout automatically.
    @ViewBuilder
    private var popover: some View {
        if isSingle {
            MapPinNameChip(name: group.elements[0].summary.name)
                .padding(chipClipMargin)
                .fixedSize()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(group.elements) { entry in
                        MapPinNameChip(
                            name: entry.summary.name,
                            isOpen: entry.reference == selection,
                            action: { onNameClick(entry.reference) }
                        )
                    }
                }
                // Breathing room inside the scroll clip so chip borders and shadows
                // aren't shaved off at the popover's edges.
                .padding(chipClipMargin)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxPopoverHeight)
            .fixedSize()
        }
    }

    private var chipClipMargin: CGFloat { 3 }
}

/// One name chip in a pin's popover: its own rounded `.regularMaterial` plate with a
/// hairline border and a soft shadow. The currently-open card's chip is accent-tinted —
/// the row's only open-indicator (Feature 4; replaced the earlier checkmark so there's
/// exactly one clear signal); on macOS the other chips get a standard subtle highlight
/// under the pointer. Both tints are background-only, so hovering or opening never changes
/// a chip's geometry — the hidden measuring twin (which renders un-hovered) stays exact.
///
/// `action == nil` renders the same chrome without a button: the single-pin hover preview,
/// which isn't clickable — clicking the pin itself navigates.
private struct MapPinNameChip: View {
    let name: String
    var isOpen: Bool = false
    var action: (() -> Void)?

    @State private var isRowHovered = false

    var body: some View {
        if let action {
            rowHoverTracked(
                Button(action: action) { label }
                    .buttonStyle(.plain)
            )
            .accessibilityIdentifier(name)
            .accessibilityAddTraits(isOpen ? .isSelected : [])
        } else {
            label
        }
    }

    private var label: some View {
        Text(name)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                ZStack {
                    chipShape.fill(.regularMaterial)
                    if isOpen {
                        chipShape.fill(Color.accentColor.opacity(0.18))
                    } else if isRowHovered {
                        chipShape.fill(Color.primary.opacity(0.07))
                    }
                }
                // On the background plate only (not the composed row) so the text isn't
                // shadowed along with the chip.
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            .overlay(chipShape.strokeBorder(.quaternary, lineWidth: 1))
            .contentShape(chipShape)
    }

    private var chipShape: RoundedRectangle { RoundedRectangle(cornerRadius: 8) }

    /// macOS-only pointer highlight; other platforms have no hover to track.
    private func rowHoverTracked(_ view: some View) -> some View {
        #if os(macOS)
        return view.onHover { isRowHovered = $0 }
        #else
        return view
        #endif
    }
}
