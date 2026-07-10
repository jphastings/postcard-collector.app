import SwiftUI

/// Shows one postcard full-size: a tap-to-flip 3D card, plus an info sheet/inspector with
/// its metadata.
struct CardDetailView: View {
    let reference: CardReference

    @State private var splitImage: SplitPostcardImage?
    @State private var metadata: PostcardMetadata?
    @State private var loadError: String?
    @State private var showingInfo = false

    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var lastZoomOffset: CGSize = .zero
    @State private var contentSize: CGSize = .zero

    // Single tap flips instantly (no delay waiting to see if a second tap arrives); a second
    // tap within `doubleTapWindow` reverses that flip and zooms instead. Driving the flip via
    // this binding (rather than FlippableCardView's own `tapToFlip`) lets both gestures share
    // one recognizer instead of fighting over the same touch.
    @State private var isFlipped = false
    @State private var lastTapTime: Date?
    private let doubleTapWindow: TimeInterval = 0.3
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
                    Button("Info", systemImage: "info.circle") {
                        showingInfo.toggle()
                    }
                    .disabled(metadata == nil)
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingInfo) { infoPanel }
            #else
            .inspector(isPresented: $showingInfo) { infoPanel }
            #endif
            .task(id: reference.id) { await load() }
    }

    @ViewBuilder
    private var infoPanel: some View {
        if let metadata {
            CardInfoPanel(summary: reference.summary, metadata: metadata)
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
                // translation arrives in the gesture's pre-transform space (this view is
                // captured before .scaleEffect), so it must be scaled up to match how far the
                // finger has actually travelled on screen — otherwise pan lags behind at
                // any zoom > 1x.
                zoomOffset = CGSize(
                    width: lastZoomOffset.width + value.translation.width * zoomScale,
                    height: lastZoomOffset.height + value.translation.height * zoomScale
                )
            }
            .onEnded { _ in
                guard zoomScale > minZoomScale else { return }
                lastZoomOffset = zoomOffset
            }
    }

    // Local space: the tap location must be in the same pre-transform coordinate space as
    // `contentSize` for ZoomGeometry's anchor math (see its doc comment).
    private var tapGesture: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .local)
            .onEnded { value in
                handleTap(at: value.location)
            }
    }

    private var canFlip: Bool {
        splitImage?.back != nil && reference.summary.flip != .none
    }

    private func handleTap(at location: CGPoint) {
        if let lastTapTime, Date().timeIntervalSince(lastTapTime) < doubleTapWindow {
            // Second tap: reverse the flip the first tap started, and zoom instead.
            if canFlip {
                isFlipped.toggle()
            }
            toggleZoom(at: location)
            self.lastTapTime = nil
        } else {
            // First tap: flip starts immediately, with no wait to see if a second tap follows.
            if canFlip {
                isFlipped.toggle()
            }
            lastTapTime = Date()
        }
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
            .padding(16)
            // Fills the whole detail area (rather than just the card's aspect-fitted band) so
            // zoomed content has the full screen to pan across instead of being clipped back
            // to a small centered band.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // Captured before scale/offset so gesture locations stay in one stable coordinate
            // space regardless of current zoom/pan — see ZoomGeometry's doc comment.
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { contentSize = proxy.size }
                        .onChange(of: proxy.size) { _, newValue in contentSize = newValue }
                }
            }
            .gesture(magnifyGesture)
            .simultaneousGesture(panGesture)
            .simultaneousGesture(tapGesture)
            .scaleEffect(zoomScale)
            .offset(zoomOffset)
            // Zoomed/panned content would otherwise spill past the detail pane's bounds.
            .clipped()
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
        lastTapTime = nil
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
