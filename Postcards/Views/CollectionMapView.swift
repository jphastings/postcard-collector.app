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
/// Cluster split/merge animation — pins are GEOGRAPHICALLY ANCHORED AT ALL TIMES: every
/// located card owns exactly ONE annotation, keyed by its OWN card id (stable identity, so
/// SwiftUI never tears one down and recreates it as clustering changes), and the
/// annotation's `coordinate` IS its display position — the card's own lat/long when
/// unclustered, its cluster's centroid (a real geographic coordinate) when clustered.
/// MapKit therefore tracks every pin perfectly through any gesture: zero drift, always
/// exactly on its lat/long spot. (A previous design anchored each pin at its own
/// coordinate plus a persistent screen-point offset onto the centroid — but a fixed pixel
/// vector spans different geography at every zoom level, so pins drifted relative to the
/// map during scroll-wheel zooms.)
///
/// The glide is a FLIP transition applied only at camera settle
/// (`.onMapCameraChange(frequency: .onEnd)`), when membership — and with it some pins'
/// display coordinates — changes: each moved pin's new geo coordinate is set immediately,
/// the screen-space delta from its old displayed position to its new one (both projected
/// at the settled camera — see `MapPinClustering.flipDeltas`) is applied as an initial
/// INVERSE `.offset` in the same non-animated update (so nothing visibly moves yet), and
/// that offset is then animated to zero — the pin visually glides from where it stood to
/// its new geo anchor and ends offset-free, so subsequent gestures track geography
/// exactly. The animated phase is RENDER-ANCHORED: it triggers from a `.task(id:)` inside
/// the annotation content, which runs only after the snapped phase has been committed —
/// a fixed timer here raced the first render, and losing that race collapsed both phases
/// into one frame (net-zero attribute change, no glide, pins teleporting).
///
/// Membership is TWO-LAYERED so badges never lead the motion (the choreography):
/// - POSITIONAL membership (`screenClusters`) drives each annotation's geo coordinate and
///   the FLIP offsets. It updates at the settle, always.
/// - VISUAL membership (`visualClusters`) drives badges, popover contents, and which of a
///   stack of overlapping pins is visible. While a glide is in motion, every group with a
///   moved member decomposes into plain singletons (`MapPinClustering.motionVisualGroups`),
///   so a SPLIT reads as: badge off → the single pin becomes several plain pins → they
///   glide apart; and a MERGE reads as: plain pins glide together → THEN the count badge
///   fades in (~120ms) and the now perfectly-stacked redundant pins turn invisible.
///   Visual membership resolves back to positional only when the glide has ACTUALLY
///   finished: each gliding member reports terminal progress from inside its own
///   annotation content (`GlideOffsetEffect`, the Animatable-`animatableData` completion
///   technique — see `MapGlideArrival`), and resolution runs once every member of the
///   settle has arrived, with a duration-matched timer as fallback. NOT from
///   `withAnimation(completionCriteria:)`: that completion is tied to the OUTER
///   transaction, which animates nothing here (MapKit's hosting boundary is why the glide
///   runs on a value-scoped animation inside the content), so `.logicallyComplete` fired
///   at t≈0 and hid a merge's stacked pins before their glide drew a single frame — pins
///   vanished in place instead of gliding.
///
/// Trade-off, deliberate: if a new gesture starts mid-glide, all glide offsets snap to
/// zero immediately (non-animated) AND visual membership resolves straight to its final
/// state — affected pins jump by at most the remaining glide distance, but stay
/// geo-correct throughout the gesture, and badges are never left mid-sequence.
/// Distinguishing a real gesture from the `.continuous` echo of the settle itself
/// (delivery order between the two frequencies isn't contractual, and the echo's camera
/// carries floating-point drift) is `MapCameraMotion.isMaterialMotion`'s job — an exact
/// camera comparison here once classified that drift as motion and cancelled every glide
/// on the frame it started (the other half of the teleport bug).
///
/// Every card keeps ONE STRUCTURALLY IDENTICAL annotation at all times — the same button,
/// glyph, badge and popover slot whether it's a cluster's visible representative or a
/// hidden stacked member — with visibility and interactivity driven by opacity and
/// hit-testing rather than by swapping views, so SwiftUI never rebuilds a pin's content
/// mid-choreography (a structural swap resets identity and kills in-flight animations).
/// Only the VISUAL group's representative (first member, stable order) is visible and
/// interactive; the rest sit exactly stacked, invisible and untouchable, ready to glide
/// out as themselves when their cluster splits. The popover overlay stays conditionally
/// mounted per invariant (a) below — that compositor quirk bites live interactive
/// content; a static glyph's opacity is the same technique the popover's own row tints
/// already use safely.
struct CollectionMapView: View {
    let entries: [MapCardEntry]
    @Binding var selection: CardReference?

    @State private var cameraPosition: MapCameraPosition
    /// The group whose popover is held open by click/tap (macOS hover shows popovers
    /// without touching this). At most one at a time.
    @State private var openGroupID: String?
    /// POSITIONAL membership — the current zoom's screen-space clusters; `nil` until the
    /// first camera settle makes projection possible, when exact-coordinate grouping
    /// stands in. Drives annotation coordinates and FLIP offsets.
    @State private var screenClusters: [MapPinGroup<MapCardEntry>]?
    /// VISUAL membership during a glide (see the type's doc comment) — badges, popover
    /// contents and stacked-pin visibility read from this; `nil` means "same as
    /// positional", the steady state.
    @State private var visualClusters: [MapPinGroup<MapCardEntry>]?
    /// The active FLIP's per-card inverse deltas (old display point − new, at the settled
    /// camera; see the type's doc comment) — set when a settle changes membership, cleared
    /// the moment a new gesture starts. Cards without an entry aren't gliding.
    @State private var glideDeltas: [String: CGSize] = [:]
    /// The FLIP's animatable phase: snapped to 1 (full inverse offset, non-animated) as a
    /// glide begins, then animated to 0. Each pin renders at `delta × progress`, so
    /// clearing `glideDeltas` zeroes every offset instantly regardless of where this
    /// value's in-flight animation currently is — that's the gesture-interrupt snap.
    @State private var glideProgress: CGFloat = 0
    /// Bumped each settle that starts a glide; the annotations' `.task(id:)` — the
    /// render-anchored phase-2 trigger — re-runs on each new value, after the snapped
    /// phase-1 content has been committed.
    @State private var glideGeneration = 0
    /// Bumped on EVERY settle; glide completions capture it so a completion from a
    /// superseded settle can't resolve a newer choreography early.
    @State private var settleGeneration = 0
    /// The gliding members that have reported terminal progress this settle (see
    /// `GlideOffsetEffect`/`glideArrived`); once it covers every key of `glideDeltas`,
    /// the choreography's final beat runs. Reset by every settle and interrupt.
    @State private var glideArrivals: Set<String> = []
    /// The camera recorded at the last settle, for telling real gestures apart from the
    /// settle's own `.continuous` echo (see `MapCameraMotion.isMaterialMotion`).
    @State private var settledCamera: MapCamera?

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

    /// The FLIP glide's duration; the badge fade at a merge's end is deliberately much
    /// shorter — it's a reveal, not a movement.
    static let glideDuration: TimeInterval = 0.35

    private var groups: [MapPinGroup<MapCardEntry>] {
        screenClusters ?? MapPinGrouping.groups(of: entries) { $0.summary.coordinate }
    }

    private var visualGroups: [MapPinGroup<MapCardEntry>] {
        visualClusters ?? groups
    }

    /// Each located card's POSITIONAL cluster (coordinate + FLIP source of truth), plus
    /// whether it's that cluster's representative — keyed by card id.
    private var positionalMembership: [String: (group: MapPinGroup<MapCardEntry>, isRepresentative: Bool)] {
        MapPinClustering.membership(of: groups)
    }

    /// Each located card's VISUAL cluster (badge/popover/visibility source of truth) —
    /// identical to `positionalMembership` except while a glide's choreography is running.
    private var visualMembership: [String: (group: MapPinGroup<MapCardEntry>, isRepresentative: Bool)] {
        MapPinClustering.membership(of: visualGroups)
    }

    var body: some View {
        GeometryReader { geometry in
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    ForEach(locatedEntries) { entry in
                        if let positional = positionalMembership[entry.id], let visual = visualMembership[entry.id] {
                            // Qualified: `Models.swift` already declares its own
                            // `Annotation` (for postcard transcriptions), which shadows
                            // MapKit's SwiftUI `Annotation` content type in this module.
                            // The label builder is empty on purpose — always-visible names
                            // under every pin were clutter; names live in the popover
                            // instead. The coordinate is this card's POSITIONAL display
                            // position — its cluster's coordinate (own lat/long when
                            // singleton, the centroid otherwise), so MapKit itself keeps
                            // the pin geographically anchored through every gesture; the
                            // pin's APPEARANCE follows its VISUAL group — see the type's
                            // doc comment on the two layers.
                            MapKit.Annotation(coordinate: positional.group.coordinate, anchor: .bottom) {
                                MapPinAnnotation(
                                    group: visual.group,
                                    isRepresentative: visual.isRepresentative,
                                    isOpen: openGroupID == visual.group.id,
                                    selection: selection,
                                    glideDelta: glideDeltas[entry.id] ?? .zero,
                                    glideProgress: glideProgress,
                                    glideGeneration: glideGeneration,
                                    maxPopoverHeight: MapPopoverSizing.maxHeight(forAvailableHeight: geometry.size.height),
                                    onGlideReady: startGlide,
                                    onGlideArrival: { glideArrived(entry.id) },
                                    onPinClick: { pinClicked(visual.group) },
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
                // Membership recomputes ONLY when the camera FULLY settles — `.onEnd` IS
                // the settle signal, so no debounce is needed. Mid-gesture the pins need
                // no help at all: their annotation coordinates are their display
                // positions, so MapKit tracks them geographically for free.
                .onMapCameraChange(frequency: .onEnd) { context in
                    settledCamera = context.camera
                    recluster(with: proxy)
                }
                // A MATERIAL camera change (as opposed to a settle, or the settle's own
                // floating-point-drifted echo — see `MapCameraMotion`) means a gesture is
                // underway: snap any in-flight glide to zero and resolve its visual
                // membership, so every pin sits exactly on its geo anchor, correctly
                // badged, for the whole gesture. The jump is at most the glide's
                // remaining distance — the documented trade-off in the type's doc comment.
                .onMapCameraChange(frequency: .continuous) { context in
                    guard MapCameraMotion.isMaterialMotion(context.camera, since: settledCamera) else { return }
                    cancelGlideIfActive()
                }
                // A new entry set (search narrowing, collection switch) re-clusters
                // immediately — there's no gesture to wait out, and its pins may bear no
                // relation to the previous clusters. Surviving pins whose display
                // coordinate moves get the same FLIP glide.
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
        // The FLIP: for every card whose display coordinate is about to move, the inverse
        // screen-space delta that visually holds it at its OLD position once the state
        // below re-anchors it to the new one.
        let deltas = MapPinClustering.flipDeltas(from: groups, to: newGroups) { coordinate in
            proxy.convert(coordinate, to: .local)
        }

        settleGeneration += 1
        screenClusters = newGroups
        glideDeltas = deltas
        glideArrivals = []
        if deltas.isEmpty {
            // Nothing moved: no choreography — visuals match positions immediately.
            visualClusters = nil
            glideProgress = 0
        } else {
            // Phase 1 (this update, nothing animated — the annotations' glide animation
            // only engages when `glideProgress` becomes 0): coordinates jump to their new
            // geo anchors while the full-strength inverse offsets (`progress == 1`) hold
            // every moved pin visually where it was; simultaneously, every group touched
            // by the change decomposes VISUALLY into plain singletons — a splitting
            // cluster's badge disappears right here, before any motion, and a merging
            // cluster's badge won't exist until the glide completes.
            visualClusters = MapPinClustering.motionVisualGroups(
                positional: newGroups,
                moved: Set(deltas.keys),
                ownCoordinate: { $0.summary.coordinate }
            )
            glideProgress = 1
            // Phase 2 — the glide itself — is triggered by the annotations' render-
            // anchored `.task(id: glideGeneration)` (see `MapPinAnnotation`), so it can't
            // race this update's render. The backup below covers the task never firing
            // (hosted-content lifecycle quirks): by 80ms the snap has long rendered, so
            // triggering from here is safe too. Both paths funnel into `startGlide`,
            // which is idempotent.
            glideGeneration += 1
            let generation = settleGeneration
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                guard generation == settleGeneration else { return }
                startGlide()
            }
        }

        // The open popover's (visual) group no longer exists once its cards no longer
        // share a pin — keeping a stale id around would just never match again.
        let validGroupIDs = Set((visualClusters ?? newGroups).map(\.id))
        if let openGroupID, !validGroupIDs.contains(openGroupID) {
            self.openGroupID = nil
        }
    }

    /// Phase 2 of the FLIP: animates the held-back offsets to zero — the visible glide.
    /// Idempotent: called once per glide by whichever of the render-anchored task or the
    /// backup timer gets there first.
    ///
    /// Resolution of the choreography (badges after convergence) is NOT gated on this
    /// transaction's completion: the outer transaction animates nothing — the glide runs
    /// on the value-scoped animation inside each annotation's hosted content — so
    /// `withAnimation(completionCriteria:)` reported "logically complete" at t≈0 and hid
    /// a merge's stacked pins before their glide drew a frame. Instead each gliding
    /// member reports its own terminal progress from inside the animation
    /// (`GlideOffsetEffect` → `glideArrived`), with the duration-matched timer below as
    /// the fallback for anything that keeps the reports from arriving.
    private func startGlide() {
        guard glideProgress == 1 else { return }
        let generation = settleGeneration
        withAnimation(.easeInOut(duration: Self.glideDuration)) {
            glideProgress = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(Self.glideDuration * 1000) + 80))
            resolveVisualMembership(afterSettle: generation)
        }
    }

    /// One gliding member's animation reached its target (see `GlideOffsetEffect`). Once
    /// every member of the CURRENT settle's glide has arrived, the choreography resolves.
    /// Self-guarding against staleness: a newer settle resets `glideArrivals` and snaps
    /// `glideProgress` back to 1, so reports from a superseded animation can't resolve
    /// the new choreography early; duplicate reports (interpolation can graze the
    /// terminal band over several frames) are absorbed by the set.
    private func glideArrived(_ id: String) {
        guard glideProgress == 0, glideDeltas[id] != nil else { return }
        glideArrivals.insert(id)
        if glideArrivals.isSuperset(of: glideDeltas.keys) {
            resolveVisualMembership(afterSettle: settleGeneration)
        }
    }

    /// The choreography's final beat: visual membership snaps back to positional — a
    /// merged cluster's badge fades in (the badge's own appear-animation; see
    /// `MapPinAnnotation`) and its redundant, now perfectly-stacked pins turn invisible.
    /// No-ops for superseded settles and for already-resolved choreography.
    private func resolveVisualMembership(afterSettle generation: Int) {
        guard generation == settleGeneration else { return }
        guard visualClusters != nil || !glideDeltas.isEmpty else { return }
        visualClusters = nil
        glideDeltas = [:]
    }

    /// The gesture-interrupt snap (see the type's doc comment on the trade-off): zeroing
    /// the deltas zeroes every rendered offset instantly — `delta × progress` is zero
    /// whatever `progress`'s in-flight animation is doing — and visual membership resolves
    /// straight to its final state, so pins are geo-anchored and correctly badged for the
    /// whole gesture. `glideProgress` is deliberately left alone: it isn't rendered once
    /// the deltas are gone, and changing it here would engage the value-scoped glide
    /// animation on the very change that must snap.
    private func cancelGlideIfActive() {
        guard visualClusters != nil || !glideDeltas.isEmpty else { return }
        glideDeltas = [:]
        glideArrivals = []
        visualClusters = nil
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

/// One card's annotation content: a structurally constant stack — popover slot, pin
/// button, badge — whose visibility and interactivity are driven by the card's VISUAL
/// group (see the file's doc comment on the two membership layers): only the visual
/// representative is visible and clickable; a hidden stacked member renders the identical
/// structure at opacity 0 so its view identity (and any in-flight glide animation)
/// survives every membership change.
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
    /// The card's VISUAL group — drives the badge, popover names, and visibility.
    let group: MapPinGroup<MapCardEntry>
    /// Whether this card is its VISUAL group's representative (first member): the one
    /// visible, hit-testable pin of a stack.
    let isRepresentative: Bool
    let isOpen: Bool
    let selection: CardReference?
    /// This card's FLIP inverse delta — `.zero` unless a glide is in progress (see
    /// `CollectionMapView`'s doc comment).
    let glideDelta: CGSize
    /// The FLIP phase: 1 = held at the old position (snap), 0 = at the geo anchor. The
    /// rendered offset is `glideDelta × glideProgress`, so a cleared delta zeroes the
    /// offset instantly regardless of this value's in-flight animation.
    let glideProgress: CGFloat
    /// Re-triggers the render-anchored `.task(id:)` below — the glide's phase-2 trigger.
    let glideGeneration: Int
    let maxPopoverHeight: CGFloat
    let onGlideReady: () -> Void
    /// This card's glide animation reached its target (reported from INSIDE the animation
    /// by `GlideOffsetEffect`) — the choreography's true completion signal.
    let onGlideArrival: () -> Void
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
            // ALWAYS the same button structure, whether or not this card is the visible
            // representative — swapping between a button and a plain glyph on membership
            // changes would rebuild the subtree and reset its identity mid-choreography
            // (see the file's doc comment). Hidden stacked members are opacity-0 and
            // untouchable; the opacity technique is safe here (invariant (a)'s compositor
            // quirk bites live interactive content — hit-testing is off when hidden).
            hoverTracked(pinButton)
                .opacity(isRepresentative ? 1 : 0)
                .allowsHitTesting(isRepresentative)
                .accessibilityHidden(!isRepresentative)
        }
        .modifier(GlideOffsetEffect(delta: glideDelta, progress: glideProgress, onArrival: onGlideArrival))
        .animation(.easeInOut(duration: 0.15), value: showsPopover)
        // The FLIP glide. Explicit, VALUE-SCOPED animation rather than an ambient
        // `withAnimation` in `CollectionMapView`: each annotation's content is hosted by
        // MapKit's own bridging (the same boundary invariant (a) warns about elsewhere in
        // this file), which does not reliably forward an outer transaction into that
        // hosted content — exactly why `showsPopover` above already gets its own explicit
        // `.animation(value:)`. The animation is CONDITIONAL on the phase direction:
        // engaged only when `glideProgress` lands on 0 (the glide toward the geo anchor);
        // the snap to 1 — which accompanies the coordinate jump and must render
        // instantaneously with it — passes `nil` and doesn't animate. Changes driven by
        // `glideDelta` alone (the gesture-interrupt clear) aren't tied to this value, so
        // they snap too.
        .animation(glideProgress == 0 ? .easeInOut(duration: CollectionMapView.glideDuration) : nil, value: glideProgress)
        // The glide's phase-2 trigger, RENDER-ANCHORED: `.task(id:)` re-runs when the
        // generation changes, and only after this annotation's phase-1 content (snapped
        // offset, decomposed visual groups) has been committed — a fixed-delay timer
        // raced that first render and could collapse both phases into one frame (no
        // glide at all). Every gliding annotation calls in; `onGlideReady` is idempotent.
        .task(id: glideGeneration) {
            guard glideDelta != .zero else { return }
            onGlideReady()
        }
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

    /// The pin's glyph and count badge. The badge is PERMANENTLY MOUNTED and driven by
    /// opacity/scale — conditional mounting would change the pin's structure between
    /// clustered and unclustered states, resetting identity mid-choreography. Appearing
    /// (a merge's final beat, after the glide completes) fades/scales in over ~120ms;
    /// disappearing (a split's first beat, before any motion) snaps off instantly — the
    /// nil animation when `badgeVisible` turns false — so badges never lead the movement.
    private var pinGlyph: some View {
        Image(systemName: "mappin.circle.fill")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .red)
            .background(Circle().fill(.white).padding(3))
            .overlay(alignment: .topTrailing) {
                // max(…, 2): the text needs SOME content while hidden at count 1; a real
                // count is only ever visible when the group has more than one member.
                Text("\(max(group.elements.count, 2))")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(.blue))
                    .offset(x: 7, y: -7)
                    .opacity(badgeVisible ? 1 : 0)
                    .scaleEffect(badgeVisible ? 1 : 0.5)
                    .animation(badgeVisible ? .easeOut(duration: 0.12) : nil, value: badgeVisible)
            }
    }

    private var badgeVisible: Bool { !isSingle }

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

/// The FLIP glide's offset (`delta × progress`) with TRUE completion reporting, measured
/// inside the hosted annotation content where the value-scoped animation actually runs.
/// `Animatable` is the load-bearing part (the same technique `FlipFace` uses for its
/// backface cut): SwiftUI calls the `animatableData` setter with interpolated progress
/// every frame of the glide, so the frame that reaches the terminal band around zero IS
/// the animation's real completion (`MapGlideArrival.hasArrived`). This exists because
/// `withAnimation(_:completionCriteria:completion:)` reports on the OUTER transaction —
/// which animates nothing here, since MapKit's hosting boundary is why the glide runs on
/// a value-scoped animation inside the content — so `.logicallyComplete` fired at t≈0 and
/// resolved a merge's visuals (hiding its stacked pins) before the glide drew one frame.
///
/// Non-animated changes never report: an interrupt clears `delta` (so `hasArrived` is
/// false whatever the progress), and phase 1's snap sets progress to 1, the far end of
/// the terminal band. Grazing the band across several closing frames can report more than
/// once; the parent's arrival set absorbs duplicates.
private struct GlideOffsetEffect: ViewModifier, Animatable {
    var delta: CGSize
    var progress: CGFloat
    var onArrival: () -> Void

    var animatableData: CGFloat {
        get { progress }
        set {
            progress = newValue
            if MapGlideArrival.hasArrived(progress: newValue, delta: delta) {
                // Async: this setter runs during render interpolation, and the callback
                // mutates view state, which must not happen mid-render.
                let report = onArrival
                DispatchQueue.main.async(execute: report)
            }
        }
    }

    func body(content: Content) -> some View {
        content.offset(CGSize(width: delta.width * progress, height: delta.height * progress))
    }
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
