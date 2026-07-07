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

    private let minZoomScale: CGFloat = 1
    private let maxZoomScale: CGFloat = 5

    var body: some View {
        content
            .navigationTitle(reference.summary.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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

    // Pinch handles magnification directly; drag only pans once zoomed in, so it must run
    // alongside (not replace) FlippableCardView's own internal tap-to-flip gesture.
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
                )
            )
            .padding(40)
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
            .scaleEffect(zoomScale)
            .offset(zoomOffset)
            // Zoomed/panned content would otherwise spill past the detail pane's bounds.
            .clipped()
            .overlay(alignment: .topTrailing) {
                if zoomScale > minZoomScale {
                    Button {
                        resetZoom()
                    } label: {
                        Label("Reset Zoom", systemImage: "arrow.down.right.and.arrow.up.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: zoomScale > minZoomScale)
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
