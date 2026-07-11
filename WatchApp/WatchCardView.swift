import CoreGraphics
import SwiftUI

/// One postcard, filling one screen of `WatchPostcardScrollView`'s snap-scroll. Owns both of
/// its gestures on a single container — a single tap flips the card, a double tap toggles a
/// 2.5x zoom — rather than nesting a second tap recognizer inside `FlippableCardView`'s own,
/// which is exactly the ambiguity `tapToFlip`/`isFlipped` were added to `FlippableCardView`
/// to avoid: SwiftUI cleanly disambiguates single- vs double-tap only when both gestures are
/// attached to the same view.
///
/// The card's own image blobs may not have arrived yet — `meta` (from the collection's
/// manifest) is enough to lay out an aspect-correct placeholder slot immediately, and this
/// view reacts the moment `library.hasScreenFaces(...)` goes true. The phone does all pixel
/// work (splitting/rotating) before sending each face, so this view only ever decodes —
/// through `library.decodedFaceCache` — never crops or rotates.
struct WatchCardView: View {
    let library: WatchLibrary
    let collectionID: String
    let meta: WatchCardMeta
    /// Reported up to the scroll view so it can disable paging while this card is zoomed —
    /// set to this card's name while zoomed, `nil` once the zoom resets.
    @Binding var zoomedCardID: String?

    private static let zoomScale: CGFloat = 2.5

    private enum LoadState {
        case waiting
        case failed(String)
        case loaded(front: CGImage, back: CGImage?)
    }

    @State private var loadState: LoadState = .waiting
    @State private var zoomFront: CGImage?
    @State private var zoomBack: CGImage?
    @State private var isFlipped = false
    @State private var isZoomed = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var containerSize: CGSize = .zero

    private var aspectRatio: CGFloat {
        guard meta.frontPxH > 0 else { return 1 }
        return CGFloat(meta.frontPxW) / CGFloat(meta.frontPxH)
    }

    private var hasBack: Bool { meta.flip != .none }

    /// Reading `library.hasScreenFaces(...)` here (rather than only inside `loadScreenFaces()`)
    /// is what makes this `@Observable`-tracked: SwiftUI only re-renders `body` for state
    /// actually read during a previous render, so gating `.task(id:)` on this — not on
    /// `cardBlobURL`, which touches disk rather than observable state — is what notices a face
    /// landing.
    private var isReceived: Bool {
        library.hasScreenFaces(id: collectionID, cardName: meta.name, hasBack: hasBack)
    }

    private struct ZoomLoadTrigger: Equatable {
        let isZoomed: Bool
        let hasZoomFaces: Bool
    }

    private var zoomLoadTrigger: ZoomLoadTrigger {
        ZoomLoadTrigger(
            isZoomed: isZoomed,
            hasZoomFaces: library.hasZoomFaces(id: collectionID, cardName: meta.name, hasBack: hasBack)
        )
    }

    var body: some View {
        content
            .task(id: isReceived) { await loadScreenFaces() }
            .task(id: zoomLoadTrigger) { await loadZoomFacesIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .waiting:
            ProgressView()
                .aspectRatio(aspectRatio, contentMode: .fit)
        case .failed(let message):
            ContentUnavailableView(
                "Can't Load Card",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let front, let back):
            FlippableCardView(
                front: zoomFront ?? front,
                back: zoomBack ?? back,
                flip: meta.flip,
                frontPixelSize: CGSize(width: meta.frontPxW, height: meta.frontPxH),
                tapToFlip: false,
                isFlipped: $isFlipped
            )
            .padding(8)
            .background {
                // Captured before scale/offset so drag translation and the zoom clamp both
                // work in one stable, unscaled coordinate space — see `ZoomGeometry`.
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerSize = proxy.size }
                        .onChange(of: proxy.size) { _, newValue in containerSize = newValue }
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleZoom() }
            .onTapGesture(count: 1) { isFlipped.toggle() }
            .simultaneousGesture(panGesture)
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard isZoomed else { return }
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = ZoomGeometry.clampedOffset(proposed, scale: scale, containerSize: containerSize)
            }
            .onEnded { _ in
                guard isZoomed else { return }
                lastOffset = offset
            }
    }

    private func toggleZoom() {
        let zooming = !isZoomed
        withAnimation(.easeInOut(duration: 0.25)) {
            isZoomed = zooming
            scale = zooming ? Self.zoomScale : 1
            if !zooming {
                offset = .zero
                lastOffset = .zero
            }
        }
        zoomedCardID = zooming ? meta.name : nil
    }

    private func loadScreenFaces() async {
        guard let frontURL = library.cardBlobURL(collectionID, cardName: meta.name, tier: WatchRelay.tierScreen, side: WatchRelay.sideFront) else {
            loadState = .waiting
            return
        }
        let frontKey = WatchFaceKey(id: collectionID, cardName: meta.name, tier: WatchRelay.tierScreen, side: WatchRelay.sideFront)
        guard let front = await library.decodedFaceCache.decodedFace(frontKey, at: frontURL) else {
            loadState = .failed("Couldn't decode this postcard's image.")
            return
        }
        guard hasBack else {
            loadState = .loaded(front: front, back: nil)
            return
        }
        guard let backURL = library.cardBlobURL(collectionID, cardName: meta.name, tier: WatchRelay.tierScreen, side: WatchRelay.sideBack) else {
            loadState = .waiting
            return
        }
        let backKey = WatchFaceKey(id: collectionID, cardName: meta.name, tier: WatchRelay.tierScreen, side: WatchRelay.sideBack)
        guard let back = await library.decodedFaceCache.decodedFace(backKey, at: backURL) else {
            loadState = .failed("Couldn't decode this postcard's image.")
            return
        }
        loadState = .loaded(front: front, back: back)
    }

    private func loadZoomFacesIfNeeded() async {
        guard isZoomed, library.hasZoomFaces(id: collectionID, cardName: meta.name, hasBack: hasBack) else { return }
        guard let frontURL = library.cardBlobURL(collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: WatchRelay.sideFront) else { return }
        let frontKey = WatchFaceKey(id: collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: WatchRelay.sideFront)
        guard let front = await library.decodedFaceCache.decodedFace(frontKey, at: frontURL) else { return }
        zoomFront = front

        guard hasBack else { return }
        guard let backURL = library.cardBlobURL(collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: WatchRelay.sideBack) else { return }
        let backKey = WatchFaceKey(id: collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: WatchRelay.sideBack)
        guard let back = await library.decodedFaceCache.decodedFace(backKey, at: backURL) else { return }
        zoomBack = back
    }
}
