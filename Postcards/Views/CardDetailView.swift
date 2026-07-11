import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shows one postcard full-size: a tap-to-flip 3D card, plus an info sheet/inspector with
/// its metadata.
struct CardDetailView: View {
    let reference: CardReference
    let searchRequest: SearchRequest

    @State private var splitImage: SplitPostcardImage?
    @State private var metadata: PostcardMetadata?
    @State private var loadError: String?
    @State private var showingInfo = false

    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var lastZoomOffset: CGSize = .zero
    @State private var contentSize: CGSize = .zero

    #if os(macOS)
    // Token for the trackpad-pan scroll monitor installed by `zoomableCard` — see
    // `installTrackpadPanMonitor`.
    @State private var scrollMonitor: Any?
    #endif

    // The flip is driven through this binding (with FlippableCardView's own `tapToFlip`
    // disabled) so a single container can own both the flip tap and the zoom double-tap and
    // let SwiftUI disambiguate them — see `tapGesture`.
    @State private var isFlipped = false
    private let doubleTapZoomScale: CGFloat = 2.5

    private let minZoomScale: CGFloat = 1
    private let maxZoomScale: CGFloat = 5

    var body: some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if zoomScale > minZoomScale {
                        Button("Reset Zoom", systemImage: "arrow.down.right.and.arrow.up.left") {
                            resetZoom()
                        }
                    }
                    #if os(macOS)
                    // While the inspector is open, `infoPanel`'s own `.toolbar` carries this
                    // button instead, so it reads as belonging to the inspector column it
                    // toggles rather than floating in the detail toolbar above a closed one.
                    if !showingInfo {
                        infoButton
                    }
                    #else
                    infoButton
                    #endif
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingInfo) { infoPanel }
            #else
            .inspector(isPresented: $showingInfo) { infoPanel }
            #endif
            .task(id: reference.id) { await load() }
    }

    private var infoButton: some View {
        Button("Info", systemImage: "info.circle") {
            showingInfo.toggle()
        }
        .disabled(metadata == nil)
    }

    /// Handles a person's "More from…"/"More collected by…" preset from `CardInfoPanel`:
    /// hands the new query to the shared `searchRequest` for whichever grid pane picks it up
    /// next, and — iOS only, where the info panel is a dismissible sheet rather than a
    /// persistent inspector — closes it so the user lands straight back on the grid.
    private func handleSearchPreset(_ query: String) {
        searchRequest.submit(query)
        #if os(iOS)
        showingInfo = false
        #endif
    }

    @ViewBuilder
    private var infoPanel: some View {
        if let metadata {
            CardInfoPanel(summary: reference.summary, metadata: metadata, onSearchPreset: handleSearchPreset)
                // Fresh identity per card, so its map camera and reset-button state (which live
                // in @State, and would otherwise survive across cards at this same tree
                // position) resets instead of carrying over from whatever card was shown before.
                .id(reference.id)
                #if os(macOS)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        infoButton
                    }
                }
                #endif
        }
    }

    // Pinch handles magnification directly; drag only pans once zoomed in. Both run alongside
    // `tapGesture` (below), which drives the flip/zoom taps that would otherwise compete with
    // FlippableCardView's own internal tap-to-flip gesture — disabled here via `tapToFlip: false`.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = min(max(lastZoomScale * value.magnification, minZoomScale), maxZoomScale)
                zoomOffset = ZoomGeometry.offset(
                    keepingAnchor: value.startLocation,
                    inContentOfSize: contentSize,
                    previousScale: lastZoomScale,
                    previousOffset: lastZoomOffset,
                    newScale: newScale
                )
                zoomScale = newScale
            }
            .onEnded { _ in
                lastZoomScale = zoomScale
                lastZoomOffset = zoomOffset
                if zoomScale <= minZoomScale {
                    resetZoom()
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale > minZoomScale else { return }
                // The gesture is attached to the stable, untransformed container (see
                // `content`), so translation already arrives in screen points — applying it
                // directly to `.offset` is a true 1:1 drag. Scaling it (as a naive
                // pre-transform-space correction would) double-counts the transform on every
                // frame the offset itself changes, since that offset moves the gesture's own
                // local space: a feedback loop that made the card jitter while panning.
                zoomOffset = CGSize(
                    width: lastZoomOffset.width + value.translation.width,
                    height: lastZoomOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard zoomScale > minZoomScale else { return }
                lastZoomOffset = zoomOffset
            }
    }

    // Local space: the tap location must be in the same pre-transform coordinate space as
    // `contentSize` for ZoomGeometry's anchor math (see its doc comment).
    // Standard tap disambiguation: a double tap zooms (anchored at the tap point); a single
    // tap flips, but only once the double-tap window has elapsed without a second tap.
    // `ExclusiveGesture` gives the double-tap precedence, so the single-tap flip can't fire
    // until a double-tap has been ruled out — no half-started flip for a second tap to undo.
    private var tapGesture: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .local)
            .onEnded { value in toggleZoom(at: value.location) }
            .exclusively(
                before: SpatialTapGesture(count: 1, coordinateSpace: .local)
                    .onEnded { _ in if canFlip { isFlipped.toggle() } }
            )
    }

    private var canFlip: Bool {
        splitImage?.back != nil && reference.summary.flip != .none
    }

    private func toggleZoom(at location: CGPoint) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if zoomScale > minZoomScale {
                zoomScale = 1
                lastZoomScale = 1
                zoomOffset = .zero
                lastZoomOffset = .zero
            } else {
                zoomScale = doubleTapZoomScale
                lastZoomScale = doubleTapZoomScale
                zoomOffset = ZoomGeometry.offset(
                    keepingAnchor: location,
                    inContentOfSize: contentSize,
                    previousScale: 1,
                    previousOffset: .zero,
                    newScale: doubleTapZoomScale
                )
                lastZoomOffset = zoomOffset
            }
        }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.25)) {
            zoomScale = 1
            lastZoomScale = 1
            zoomOffset = .zero
            lastZoomOffset = .zero
        }
    }

    @ViewBuilder
    private var content: some View {
        if let splitImage {
            // Outer reader sits WITHIN the safe area (it does not ignore it), so its
            // `safeAreaInsets` report the surrounding toolbar/Dynamic Island/home-indicator
            // chrome — that's threaded into `zoomableCard` to inset the at-rest card, while
            // `zoomableCard` itself ignores the safe area so zoomed/panned content can bleed
            // all the way to the physical screen edges.
            GeometryReader { safeAreaProxy in
                zoomableCard(splitImage, insets: safeAreaProxy.safeAreaInsets)
            }
        } else if let loadError {
            ContentUnavailableView(
                "Couldn't load postcard",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            ProgressView()
        }
    }

    // The gestures, `.contentShape`, and `.clipped()` attach to this GeometryReader itself —
    // a STABLE container with no `.scaleEffect`/`.offset` of its own — while the transforms
    // live on the FlippableCardView inside it. Attaching gestures to a view that is itself
    // being transformed created a feedback loop: panning updated `.offset`, which shifted the
    // gesture's own local coordinate space, which changed the next `translation` reading,
    // producing rapid jitter. Reading gesture locations from this untransformed outer space
    // keeps them stable regardless of the current zoom/pan (see also `ZoomGeometry`'s doc
    // comment, which requires anchor and `contentSize` to share one unscaled space).
    private func zoomableCard(_ splitImage: SplitPostcardImage, insets: EdgeInsets) -> some View {
        GeometryReader { proxy in
            FlippableCardView(
                front: splitImage.front,
                back: splitImage.back,
                flip: reference.summary.flip,
                frontPixelSize: CGSize(
                    width: CGFloat(reference.summary.frontPxW),
                    height: CGFloat(reference.summary.frontPxH)
                ),
                tapToFlip: false,
                isFlipped: $isFlipped
            )
            // At-rest (scale 1) inset: normally the safe-area chrome plus a 16pt margin, but
            // for a card narrow enough to fill the height while clearing the corner buttons,
            // zero — so it reaches top/bottom (see `atRestPadding`). Once zoomed, `.scaleEffect`
            // grows the card past this inset toward the physical edges — clipped only by the
            // container below, which spans the full screen.
            .padding(atRestPadding(screen: proxy.size, insets: insets))
            // Fills the whole detail area (rather than just the card's aspect-fitted band) so
            // zoomed content has the full screen to pan across instead of being clipped back
            // to a small centered band.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(zoomScale)
            .offset(zoomOffset)
            .onAppear { contentSize = proxy.size }
            .onChange(of: proxy.size) { _, newValue in contentSize = newValue }
        }
        .contentShape(Rectangle())
        .gesture(magnifyGesture)
        .simultaneousGesture(panGesture)
        .simultaneousGesture(tapGesture)
        // Zoomed/panned content would otherwise spill past the detail pane's bounds.
        .clipped()
        // Lets zoomed content reach the physical screen edges, under the translucent toolbar
        // and Dynamic Island; the at-rest inset above keeps the unzoomed card clear of both.
        .ignoresSafeArea()
        #if os(macOS)
        .onAppear { installTrackpadPanMonitor() }
        .onDisappear { removeTrackpadPanMonitor() }
        #endif
    }

    #if os(macOS)
    // Two-finger trackpad scroll pans the zoomed card, mirroring `panGesture`'s offset math so a
    // subsequent click-drag continues from wherever the scroll left off rather than jumping.
    // There's no NSViewRepresentable in this file to hang an NSPanGestureRecognizer off, so this
    // reaches past SwiftUI with a local NSEvent monitor instead, installed only while the card is
    // on screen and always removed in `removeTrackpadPanMonitor` so it can't outlive this view.
    private func installTrackpadPanMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Precise hit-testing would mean converting `event.locationInWindow` into this
            // GeometryReader's space, fighting the AppKit/SwiftUI coordinate flip for little
            // benefit — scroll only ever pans while zoomed, so gating on the key window is close
            // enough without it.
            guard zoomScale > minZoomScale, event.window === NSApp.keyWindow else { return event }
            zoomOffset = CGSize(
                width: zoomOffset.width + event.scrollingDeltaX,
                height: zoomOffset.height + event.scrollingDeltaY
            )
            lastZoomOffset = zoomOffset
            return nil
        }
    }

    private func removeTrackpadPanMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        scrollMonitor = nil
    }
    #endif

    /// The at-rest inset for the card. Normally the safe-area chrome plus 16pt, so the unzoomed
    /// card stays clear of the toolbar/Dynamic Island/home-indicator. But when the postcard is
    /// proportionally narrower than the screen — so scaling it to the full screen height leaves
    /// its width narrow enough to sit *between* the top-corner toolbar buttons — return zero, so
    /// it fills the height edge-to-edge (aspect-fit centres it horizontally, clear of the
    /// buttons). This is what makes a landscape card use the whole height instead of floating
    /// small in the middle.
    private func atRestPadding(screen: CGSize, insets: EdgeInsets) -> EdgeInsets {
        let standard = EdgeInsets(
            top: insets.top + 16, leading: insets.leading + 16,
            bottom: insets.bottom + 16, trailing: insets.trailing + 16
        )
        let bounding = FlipGeometry.boundingSize(
            forFrontSize: CGSize(width: CGFloat(reference.summary.frontPxW), height: CGFloat(reference.summary.frontPxH)),
            flip: reference.summary.flip
        )
        guard bounding.width > 0, bounding.height > 0, screen.width > 0, screen.height > 0 else { return standard }
        let cardAspect = bounding.width / bounding.height
        // Only when the card is narrower than the screen (fitting to full height keeps its width
        // on-screen); a card wider than the screen is width-bound anyway and would run under the
        // corner buttons.
        guard cardAspect < screen.width / screen.height else { return standard }
        let fullHeightWidth = screen.height * cardAspect
        // Horizontal room that still clears a top-corner toolbar button (safe inset + the button).
        let buttonClearance: CGFloat = 52
        let clearWidth = screen.width - (insets.leading + buttonClearance) - (insets.trailing + buttonClearance)
        guard fullHeightWidth <= clearWidth else { return standard }
        return EdgeInsets()
    }

    private func load() async {
        splitImage = nil
        loadError = nil
        // Must be reset too: otherwise, switching cards while the info sheet/inspector is
        // already open leaves CardInfoPanel showing the PREVIOUS card's metadata — location,
        // map and all — until the new fetch resolves.
        metadata = nil
        // Otherwise switching to a different postcard while zoomed in leaves the new one zoomed too.
        zoomScale = 1
        lastZoomScale = 1
        zoomOffset = .zero
        lastZoomOffset = .zero
        isFlipped = false
        let flip = reference.summary.flip
        do {
            async let imageData = GoCore.shared.image(for: reference)
            async let loadedMetadata = GoCore.shared.metadata(for: reference)
            let (data, resolvedMetadata) = try await (imageData, loadedMetadata)

            splitImage = try await Task.detached(priority: .userInitiated) {
                try ImageSplitter.split(data: data, flip: flip)
            }.value
            metadata = resolvedMetadata
        } catch {
            loadError = error.localizedDescription
        }
    }
}
