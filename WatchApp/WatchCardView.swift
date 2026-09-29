import CoreGraphics
import SwiftUI
import WatchKit

/// One postcard, filling one screen of `WatchPostcardScrollView`'s snap-scroll.
///
/// Its gestures all live on one untransformed container — a drag on a view inside its own
/// scale or offset feeds back into its own coordinate space and jitters:
/// - **tap** turns the card a quarter turn toward the wearer's hand, and back again — so a
///   landscape card can fill the tall screen, read with that hand raised;
/// - **swipe left or right** flips it over, turning the way it was pushed, about the card's
///   own hinge (`FlipGeometry`: a book card turns sideways, a calendar card top over bottom);
/// - **double tap** zooms in 2.5×, after which a drag pans (paging is disabled meanwhile);
/// - **long press** opens the card's info page (`onShowInfo`).
/// A tap waits out the double-tap window before turning the card — the cost of both living on
/// one surface; the flip, which feels broken when it waits, is a swipe and never does.
///
/// The card's own image blobs may not have arrived yet — `meta` (from the collection's
/// manifest) is enough to lay out an aspect-correct placeholder slot immediately, and this
/// view reacts the moment `library.hasScreenFaces(...)` goes true; if a card sits on screen
/// without them for a few seconds, it asks the phone for them directly. The phone does all
/// pixel work (splitting/rotating) before sending each face, so this view only ever decodes —
/// through `library.decodedFaceCache` — never crops or rotates pixels.
///
/// Zooming lays the card out at the zoomed size rather than scaling it up with
/// `.scaleEffect`: a scale effect magnifies whatever was rendered at rest, where laid out
/// large the images are drawn at full resolution, and the sharper zoom-tier faces (fetched as
/// the card is zoomed into, unless its collection is pinned and already has them) get to
/// show every pixel. The zoom tier is only held while zoomed: at rest it would be minified
/// several times over, which only costs memory and shimmers.
struct WatchCardView: View {
    let library: WatchLibrary
    let collectionID: String
    let meta: WatchCardMeta
    /// Reported up to the scroll view so it can disable paging while this card is zoomed —
    /// set to this card's name while zoomed, `nil` once the zoom resets.
    @Binding var zoomedCardID: String?
    /// Called on a long press: the scroll view shows this card's info page.
    let onShowInfo: () -> Void

    private static let zoomScale: CGFloat = 2.5
    /// Keeps the resting card clear of the screen's curved left and right edges.
    private static let horizontalInset: CGFloat = 4
    /// How long a card can be on screen without its images before it asks the phone for them
    /// directly — long enough for the stream's own first cards to land, short enough to feel
    /// prompt when the person has scrolled ahead of the queue.
    private static let focusDelay: Duration = .seconds(3)

    private enum LoadState {
        case waiting
        case failed(String)
        case loaded(front: CGImage, back: CGImage?)
    }

    @State private var loadState: LoadState = .waiting
    @State private var zoomFront: CGImage?
    @State private var zoomBack: CGImage?
    /// Half turns of flip, signed by the swipes that made them (see `FlippableCardView`).
    @State private var flipHalfTurns = 0
    @State private var isQuarterTurned = false
    @State private var isZoomed = false
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// `pan` as it was when the current drag began; `nil` between drags.
    @State private var panAtDragStart: CGSize?

    private var aspectRatio: CGFloat {
        guard meta.frontPxH > 0 else { return 1 }
        return CGFloat(meta.frontPxW) / CGFloat(meta.frontPxH)
    }

    private var hasBack: Bool { meta.flip != .none }

    private var frontPixelSize: CGSize { CGSize(width: meta.frontPxW, height: meta.frontPxH) }

    private var isShowingFront: Bool { FlipGeometry.showsFront(atDegrees: Double(flipHalfTurns) * 180) }

    private var rotationDegrees: Double {
        guard isQuarterTurned else { return 0 }
        return WatchCardInteraction.quarterTurnDegrees(wornOnRightWrist: WKInterfaceDevice.current().wristLocation == .right)
    }

    private var isLoaded: Bool {
        if case .loaded = loadState { return true }
        return false
    }

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
        let hasFront: Bool
        let hasBack: Bool
    }

    /// Each side separately, so the side showing sharpens the moment its zoom face lands
    /// rather than waiting for the other.
    private var zoomLoadTrigger: ZoomLoadTrigger {
        ZoomLoadTrigger(
            isZoomed: isZoomed,
            hasFront: library.hasFace(id: collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: WatchRelay.sideFront),
            hasBack: hasBack && library.hasFace(id: collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: WatchRelay.sideBack)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            card(in: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(tapsAndLongPress)
                .simultaneousGesture(swipeOrPan(in: proxy.size))
                // VoiceOver's own swipes and taps can't reach the gestures above.
                .accessibilityAction(named: "Flip") { flip(.right) }
                .accessibilityAction(named: "Turn") { turn() }
                .accessibilityAction(named: "Zoom") { toggleZoom() }
                .accessibilityAction(named: "Info") { onShowInfo() }
        }
        .zIndex(isZoomed ? 1 : 0)
        .task(id: isReceived) { await loadScreenFaces() }
        .task(id: zoomLoadTrigger) { await loadZoomFacesIfNeeded() }
    }

    @ViewBuilder
    private func card(in slot: CGSize) -> some View {
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
            let resting = restingSize(in: slot)
            FlippableCardView(
                front: zoomFront ?? front,
                back: zoomBack ?? back,
                flip: meta.flip,
                frontPixelSize: frontPixelSize,
                tapToFlip: false,
                flipHalfTurns: flipHalfTurns,
                rotationDegrees: rotationDegrees
            )
            .frame(width: resting.width * zoom, height: resting.height * zoom)
            .offset(pan)
        }
    }

    /// The space the card fits itself into at rest: the whole slot, bar the edge inset. No
    /// vertical inset — the slot runs to the physical screen edge, and the card should use all
    /// of that height (it aspect-fits itself).
    private func restingSize(in slot: CGSize) -> CGSize {
        CGSize(width: max(slot.width - 2 * Self.horizontalInset, 1), height: max(slot.height, 1))
    }

    // MARK: - Gestures

    /// A long press takes precedence over the taps; of the taps, a double (zoom) over a single
    /// (turn), which therefore waits for the double's window to pass.
    private var tapsAndLongPress: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in onShowInfo() }
            .exclusively(before: TapGesture(count: 2)
                .onEnded { toggleZoom() }
                .exclusively(before: TapGesture(count: 1)
                    .onEnded { turn() }
                )
            )
    }

    /// Pans while zoomed; otherwise a sideways swipe flips the card. Simultaneous with the
    /// scroll view's own paging, which a sideways swipe doesn't move.
    private func swipeOrPan(in slot: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard isZoomed else { return }
                let start = panAtDragStart ?? pan
                panAtDragStart = start
                pan = clampedPan(
                    CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height),
                    in: slot
                )
            }
            .onEnded { value in
                guard !isZoomed else {
                    panAtDragStart = nil
                    return
                }
                if let direction = WatchCardInteraction.swipeDirection(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                ) {
                    flip(direction)
                }
            }
    }

    private func turn() {
        guard isLoaded else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            isQuarterTurned.toggle()
            pan = .zero
        }
        panAtDragStart = nil
    }

    private func flip(_ direction: WatchCardInteraction.SwipeDirection) {
        guard isLoaded, hasBack else { return }
        // FlippableCardView animates its own angle to follow.
        flipHalfTurns += WatchCardInteraction.flipHalfTurns(for: direction)
    }

    private func toggleZoom() {
        guard isLoaded else { return }
        let zooming = !isZoomed
        withAnimation(.easeInOut(duration: 0.25)) {
            isZoomed = zooming
            zoom = zooming ? Self.zoomScale : 1
            pan = .zero
        } completion: {
            // Back to the screen tier once the zoom-out has finished, not before, so the card
            // doesn't soften while it's still large.
            guard !isZoomed else { return }
            zoomFront = nil
            zoomBack = nil
        }
        panAtDragStart = nil
        zoomedCardID = zooming ? meta.name : nil
    }

    /// Keeps the zoomed card's showing face covering the screen along any axis it overflows,
    /// and centred along any it doesn't.
    private func clampedPan(_ proposed: CGSize, in slot: CGSize) -> CGSize {
        let face = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: frontPixelSize,
            flip: meta.flip,
            showingFront: isShowingFront,
            quarterTurned: isQuarterTurned,
            fittedIn: restingSize(in: slot)
        )
        let zoomedFace = CGSize(width: face.width * zoom, height: face.height * zoom)
        return ZoomGeometry.clampedOffset(proposed, contentSize: zoomedFace, containerSize: slot)
    }

    // MARK: - Loading

    private func loadScreenFaces() async {
        guard isReceived else {
            loadState = .waiting
            // Still missing after a while on screen — the queue hasn't reached this card, or
            // the person has scrolled ahead of it — so ask for it directly.
            try? await Task.sleep(for: Self.focusDelay)
            guard !Task.isCancelled else { return }
            library.requestFocus(id: collectionID, cardName: meta.name, tier: WatchRelay.tierScreen, preferredSide: nil)
            return
        }
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

    /// While zoomed, swaps in each side's zoom face as it's available — asking the phone for
    /// any that's missing, the side showing first.
    private func loadZoomFacesIfNeeded() async {
        let trigger = zoomLoadTrigger
        guard trigger.isZoomed else { return }
        if !trigger.hasFront || (hasBack && !trigger.hasBack) {
            library.requestFocus(
                id: collectionID,
                cardName: meta.name,
                tier: WatchRelay.tierZoom,
                preferredSide: isShowingFront ? WatchRelay.sideFront : WatchRelay.sideBack
            )
        }
        if trigger.hasFront, zoomFront == nil, let image = await decodedZoomFace(side: WatchRelay.sideFront) {
            guard !Task.isCancelled, isZoomed else { return }
            zoomFront = image
        }
        if trigger.hasBack, zoomBack == nil, let image = await decodedZoomFace(side: WatchRelay.sideBack) {
            guard !Task.isCancelled, isZoomed else { return }
            zoomBack = image
        }
    }

    private func decodedZoomFace(side: String) async -> CGImage? {
        guard let url = library.cardBlobURL(collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: side) else { return nil }
        return await library.decodedFaceCache.decodedFaceUncached(at: url)
    }
}
