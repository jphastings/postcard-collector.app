import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shows one postcard full-size: a tap-to-flip 3D card, plus an info sheet/inspector with
/// its metadata.
struct CardDetailView: View {
    let reference: CardReference
    let searchRequest: SearchRequest

    // iOS only: gates `toolbarGeometry(insets:)`'s leading (back button) estimate — this view
    // is pushed (compact) with a back button, or shown directly in the iPad detail column
    // (regular) with none. Harmless on macOS, where it's always nil and unused.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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

    // The flip is driven through this binding; FlippableCardView's own `tapToFlip` is disabled
    // so this view's `tapGesture` — attached to the outer, untransformed container alongside
    // the pan/magnify gestures — owns the tap instead.
    @State private var isFlipped = false

    private let minZoomScale: CGFloat = 1
    private let maxZoomScale: CGFloat = 5

    // NSToolbar/UINavigationBar button frames aren't measurable from SwiftUI, so the toolbar's
    // button clusters are estimated per platform instead — see `toolbarGeometry(insets:)`.
    #if os(macOS)
    // The (i) button's width over the detail pane, including its trailing margin.
    private let macOSInfoButtonClusterWidth: CGFloat = 52
    #else
    // The back button's width when this view is pushed in a compact-width navigation
    // context — see `toolbarGeometry(insets:)`'s size-class gate.
    private let iOSBackButtonClusterWidth: CGFloat = 60
    // The (i) button's width, including its trailing margin.
    private let iOSInfoButtonClusterWidth: CGFloat = 52
    #endif

    var body: some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if zoomScale > minZoomScale {
                        Button("Reset Zoom", systemImage: "arrow.down.right.and.arrow.up.left") {
                            resetZoom()
                        }
                    }
                    // iOS only: macOS's (i) lives on `infoPanel`'s own toolbar instead, so it
                    // stays pinned at the window's far right whether the inspector is open or
                    // closed — see that property's doc comment.
                    #if os(iOS)
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
    /// hands the new token to the shared `searchRequest` for whichever grid pane picks it up
    /// next, and — iOS only, where the info panel is a dismissible sheet rather than a
    /// persistent inspector — closes it so the user lands straight back on the grid.
    private func handleSearchPreset(_ token: SearchToken) {
        searchRequest.submit(token: token)
        #if os(iOS)
        showingInfo = false
        #endif
    }

    // macOS only: the (i) button is attached HERE — to the `.inspector` modifier's content,
    // rather than the detail pane's own `ToolbarItemGroup` above — so it always renders as an
    // inspector-scoped toolbar item pinned at the window's far right: over the detail pane's
    // top-right when the inspector is closed, and inside/above the inspector itself once open
    // (clicking it there toggles `showingInfo` off same as ever). This content closure is
    // evaluated by `.inspector` regardless of whether the inspector is presented — confirmed by
    // an earlier attempt that kept an ALSO-unconditional (i) in the main `ToolbarItemGroup` and
    // saw two (i) buttons rendered while the inspector was closed — so the toolbar item below
    // exists, and the button is clickable, whether or not the inspector happens to be open.
    //
    // The `.toolbar` sits on the OUTER `Group` rather than inside the `if let metadata` branch,
    // so it's attached (and the (i) button rendered, disabled) even before metadata has loaded —
    // matching the previous main-toolbar (i)'s always-present-but-disabled behaviour instead of
    // making the button disappear entirely during the load.
    @ViewBuilder
    private var infoPanel: some View {
        Group {
            if let metadata {
                CardInfoPanel(summary: reference.summary, metadata: metadata, onSearchPreset: handleSearchPreset)
                    // Fresh identity per card, so its map camera and reset-button state (which
                    // live in @State, and would otherwise survive across cards at this same tree
                    // position) resets instead of carrying over from whatever card was shown
                    // before.
                    .id(reference.id)
            }
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                infoButton
            }
        }
        #endif
    }

    // Pinch handles magnification directly; drag only pans once zoomed in. Both run alongside
    // `tapGesture` (below), which drives the flip tap that would otherwise compete with
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

    // A plain single tap flips the card immediately — no exclusively-before double-tap check,
    // so the flip isn't held up waiting out a double-tap window.
    private var tapGesture: some Gesture {
        TapGesture()
            .onEnded { if canFlip { isFlipped.toggle() } }
    }

    private var canFlip: Bool {
        splitImage?.back != nil && reference.summary.flip != .none
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
            // chrome — and, on macOS, an open `.inspector`'s width as a TRAILING inset (the
            // inspector docks as real window chrome, not a NavigationSplitView column of this
            // pane's own, so it shows up here as safe area rather than shrinking `proxy.size`
            // itself) — that's threaded into `zoomableCard` to inset the at-rest card, while
            // `zoomableCard` itself ignores the safe area so zoomed/panned content can bleed
            // all the way to the physical screen edges (behind the inspector included).
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
            // At-rest (scale 1) inset: whichever of `CardFitGeometry`'s regimes fits the card
            // (and its flipped back) biggest while clearing the toolbar's buttons — see
            // `atRestPadding`. Once zoomed, `.scaleEffect` grows the card past this inset toward
            // the physical edges — clipped only by the container below, which spans the full
            // screen.
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
        // Drag-out export (see `PostcardFileExport`) is only offered at rest. Once zoomed,
        // `panGesture`'s click-drag recognizer is live and must win every pointer-down so
        // panning stays responsive — coexisting with `.draggable`'s own drag-session
        // recognizer risks exactly the kind of gesture-priority fight this file's other
        // comments describe fixing elsewhere, so it's simplest to not attach it at all rather
        // than reason about who wins. At rest `panGesture` is already a no-op (see its own
        // `guard zoomScale > minZoomScale`), so there's nothing for `.draggable` to compete
        // with there.
        .draggablePostcard(reference, enabled: zoomScale <= minZoomScale)
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

    /// The at-rest inset for the card: whatever padding lands the aspect-fit, centred bounding
    /// box (front AND back — see `FlipGeometry.boundingSize`) in whichever of
    /// `CardFitGeometry`'s regimes fits it biggest, clear of the toolbar's button clusters. See
    /// `toolbarGeometry(insets:)` for how those clusters are estimated.
    private func atRestPadding(screen: CGSize, insets: EdgeInsets) -> EdgeInsets {
        let bounding = FlipGeometry.boundingSize(
            forFrontSize: CGSize(width: CGFloat(reference.summary.frontPxW), height: CGFloat(reference.summary.frontPxH)),
            flip: reference.summary.flip
        )
        return CardFitGeometry.atRestPadding(
            paneSize: screen,
            boundingSize: bounding,
            toolbar: toolbarGeometry(insets: insets),
            bottomInset: insets.bottom,
            // On macOS, an open `.inspector` reports its width as a trailing safe-area inset on
            // this pane (see `content`'s doc comment) rather than shrinking the pane's own
            // frame — since the zoomable container ignores the safe area, its frame would
            // otherwise span the full pane including the area behind the inspector, centring
            // the at-rest card there instead of in the visible region. Feeding the inset back
            // into `atRestPadding` keeps the card clear of it. `insets.leading` is threaded
            // through too, even though nothing in this pane currently produces one, so the fix
            // isn't macOS/inspector-specific.
            leadingInset: insets.leading,
            trailingInset: insets.trailing
        )
    }

    /// Estimates the toolbar's button-band geometry for `CardFitGeometry`. `NSToolbar` is one
    /// shared bar for the whole window (not scoped per pane) and `UINavigationBar`'s buttons
    /// aren't exposed to SwiftUI either, so real button frames can't be measured — these are
    /// estimates from platform and `@State`, not measurements.
    private func toolbarGeometry(insets: EdgeInsets) -> ToolbarGeometry {
        #if os(macOS)
        // Nothing on the leading edge of the detail pane: this is a 2-column
        // NavigationSplitView now (no middle content column) — the sidebar owns the window's
        // leading toolbar items (back/add/switcher — see `CollectionBrowser`), not this pane.
        let leadingWidth: CGFloat = 0
        // The (i) button, unless the inspector is open — then it sits above the inspector,
        // outside the detail pane, so the pane's own trailing cluster is empty. (Reset Zoom
        // only ever appears while zoomed, i.e. never at rest, so it's ignored here.)
        let trailingWidth: CGFloat = showingInfo ? 0 : macOSInfoButtonClusterWidth
        let isTransparent: Bool
        if #available(macOS 15, *) {
            // LibraryView hides the window toolbar's background app-wide on macOS 15+.
            isTransparent = true
        } else {
            isTransparent = false
        }
        #else
        // The back button only exists when this view is pushed onto a compact-width
        // NavigationStack (iPhone, or a narrowed iPad) — see `CompactDetailPush`. At regular
        // width (iPad), the outer NavigationSplitView shows this view directly in its detail
        // column with no push and so no back button. The (i) button is present at rest either
        // way, regardless of whether the info sheet is showing, since the sheet floats on top
        // rather than claiming toolbar space.
        let leadingWidth: CGFloat = horizontalSizeClass == .compact ? iOSBackButtonClusterWidth : 0
        let trailingWidth: CGFloat = iOSInfoButtonClusterWidth
        // iOS bars are translucent on every OS version this app targets.
        let isTransparent = true
        #endif
        return ToolbarGeometry(
            bandHeight: insets.top, leadingWidth: leadingWidth, trailingWidth: trailingWidth, isTransparent: isTransparent
        )
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

