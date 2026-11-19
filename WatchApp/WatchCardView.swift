import CoreGraphics
import SwiftUI

/// One postcard, filling one screen of `WatchPostcardScrollView`'s snap-scroll.
///
/// Its gestures all live on one untransformed container — a drag on a view inside its own
/// scale or offset feeds back into its own coordinate space and jitters:
/// - **tap** flips it over, about the card's own hinge (`FlipGeometry`: a book card turns
///   sideways, a calendar card top over bottom);
/// - **swipe left or right** flips it too, turning the way it was pushed;
/// - **swipe up or down** moves to the next or previous postcard (`onPage`), as the crown does;
/// - **swipe up from the top** of the card pushes the collection's controls (back button and
///   title) off the screen, giving the card all of it, and **swipe down from the top** of the
///   screen brings them back (`onFullScreen`);
/// - **double tap** zooms in 2.5×, after which a drag pans (paging is disabled meanwhile), a
///   tap does nothing, and another double tap zooms back out;
/// - **long press** opens the card's info page (`onShowInfo`).
/// A tap flips the card the moment it lands rather than waiting out the double-tap window,
/// which would make every flip feel late. A double tap's second tap takes back the turn its
/// first began — only a few degrees in by then — as quickly as the zoom, so the wobble is lost
/// under it.
///
/// The swipes share one drag gesture, which also stops the scroll view's own touch scrolling
/// from starting — so a vertical swipe pages by asking the scroll view to move, rather than
/// being left to it. The crown still scrolls natively.
///
/// The card's slot is always the whole screen; while the controls are showing, the card keeps
/// to the space below them (`controlsHeight`), so hiding them re-centres it in the full slot.
/// At rest it shrinks only if its corners would otherwise fall in the screen's curved corners.
/// A portrait front on a hand flip starts fitted by itself, as big as a plain portrait card's,
/// each time it's scrolled to, and zooms out to fit its landscape back with the first flip
/// (`fitsFrontOnly`).
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
    /// Whether the collection's controls are hidden, giving the card the whole screen.
    let isFullScreen: Bool
    /// The height the collection's controls take at the top of the screen while they're
    /// showing, which the card keeps clear of.
    let controlsHeight: CGFloat
    /// Called on a long press: the scroll view shows this card's info page.
    let onShowInfo: () -> Void
    /// Called when a vertical swipe asks to move `step` cards through the collection: `1` for
    /// the next, `-1` for the previous. Made inside an animation, so the scroll view's move
    /// animates.
    let onPage: (_ step: Int) -> Void
    /// Called when a swipe from the top asks to hide the collection's controls (`true`) or
    /// bring them back (`false`). Made inside an animation.
    let onFullScreen: (_ fullScreen: Bool) -> Void

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
    /// Half turns of flip, signed by the way each turned (see `FlippableCardView`).
    @State private var flipHalfTurns = 0
    /// How the latest change to `flipHalfTurns` animates; `nil` for a full flip.
    @State private var flipHalfTurnsAnimation: Animation?
    /// Whether the card has been flipped since it was scrolled to (see `fitsFrontOnly`).
    @State private var hasFlipped = false
    @State private var taps = WatchCardInteraction.TapSequence()
    /// `hasFlipped` as it was before the last single tap flipped the card, for a second tap to
    /// restore as it takes that flip back; `nil` if that tap didn't flip it.
    @State private var hadFlippedBeforeTap: Bool?
    @State private var isZoomed = false
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// `pan` as it was when the current drag began; `nil` between drags.
    @State private var panAtDragStart: CGSize?
    /// How far the card is following a vertical swipe in progress (see
    /// `WatchCardInteraction.pageDragOffset`); 0 otherwise.
    @State private var pageDrag: CGFloat = 0

    private var aspectRatio: CGFloat {
        guard meta.frontPxH > 0 else { return 1 }
        return CGFloat(meta.frontPxW) / CGFloat(meta.frontPxH)
    }

    private var hasBack: Bool { meta.flip != .none }

    private var frontPixelSize: CGSize { CGSize(width: meta.frontPxW, height: meta.frontPxH) }

    private var isShowingFront: Bool { FlipGeometry.showsFront(atDegrees: Double(flipHalfTurns) * 180) }

    /// A portrait front on a hand flip is fitted by itself, rather than with its landscape
    /// back, each time the card is scrolled to, until it's flipped (see
    /// `FlipGeometry.startsFittedToFront`).
    private var fitsFrontOnly: Bool {
        !hasFlipped && FlipGeometry.startsFittedToFront(frontSize: frontPixelSize, flip: meta.flip)
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

    /// The side facing the viewer, as the relay names it.
    private var showingSide: String { isShowingFront ? WatchRelay.sideFront : WatchRelay.sideBack }

    /// This card's sides still missing their screen-tier faces, front first.
    private var missingScreenSides: [String] {
        (hasBack ? [WatchRelay.sideFront, WatchRelay.sideBack] : [WatchRelay.sideFront]).filter {
            !library.hasFace(id: collectionID, cardName: meta.name, tier: WatchRelay.tierScreen, side: $0)
        }
    }

    private struct ZoomLoadTrigger: Equatable {
        let isZoomed: Bool
        let side: String
        let hasZoomFace: Bool
    }

    /// Only the side showing: a zoomed card can't be flipped (a swipe pans it, a tap does
    /// nothing), so the other
    /// side's zoom face would only cost memory — several megabytes decoded — and bandwidth.
    private var zoomLoadTrigger: ZoomLoadTrigger {
        ZoomLoadTrigger(
            isZoomed: isZoomed,
            side: showingSide,
            hasZoomFace: library.hasFace(id: collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: showingSide)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let space = cardSpace(in: proxy.size)
            card(in: space)
                .offset(y: pageDrag)
                .frame(width: space.width, height: space.height)
                .contentShape(Rectangle())
                .gesture(longPressOrTap)
                .simultaneousGesture(swipeOrPan(in: space))
                // VoiceOver's own swipes and taps can't reach the gestures above (it scrolls
                // the collection itself).
                .accessibilityAction(named: "Flip") { flip(.right) }
                .accessibilityAction(named: "Zoom") { toggleZoom() }
                .accessibilityAction(named: "Info") { onShowInfo() }
                .accessibilityAction(named: Text(isFullScreen ? "Show Controls" : "Full Screen")) {
                    withAnimation(.snappy) { onFullScreen(!isFullScreen) }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
        .zIndex(isZoomed ? 1 : 0)
        .task(id: isReceived) { await loadScreenFaces() }
        .task(id: zoomLoadTrigger) { await loadZoomFacesIfNeeded() }
        // Scrolled away: the next time it's scrolled to, a card fitted by its front alone
        // starts that way again — unless it was left showing its back, which it comes back to
        // as it was.
        .onDisappear {
            if isShowingFront { hasFlipped = false }
        }
    }

    @ViewBuilder
    private func card(in space: CGSize) -> some View {
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
            let resting = restingSize(in: space)
            FlippableCardView(
                front: zoomFront ?? front,
                back: zoomBack ?? back,
                flip: meta.flip,
                frontPixelSize: frontPixelSize,
                tapToFlip: false,
                flipHalfTurns: flipHalfTurns,
                fitsFrontOnly: fitsFrontOnly,
                flipHalfTurnsAnimation: flipHalfTurnsAnimation
            )
            .frame(width: resting.width * zoom, height: resting.height * zoom)
            .offset(pan)
        }
    }

    /// The part of the slot the card has to itself, at its bottom: all of it in full screen,
    /// and otherwise all but the controls' height at the top. Its gestures measure from here.
    private func cardSpace(in slot: CGSize) -> CGSize {
        CGSize(width: slot.width, height: max(slot.height - (isFullScreen ? 0 : controlsHeight), 1))
    }

    /// The space the card fits itself into at rest: the whole of its space, bar the edge inset,
    /// shrunk only as far as keeps the fitted card's corners inside the screen's curved ones
    /// (`WatchCardInteraction.cornerClearanceScale`). No vertical inset — the space runs to the
    /// physical screen edge, and the card should use all of that height (it aspect-fits itself).
    private func restingSize(in space: CGSize) -> CGSize {
        let box = CGSize(width: max(space.width - 2 * Self.horizontalInset, 1), height: max(space.height, 1))
        // The slot is the whole screen, with the space at its bottom.
        let top = isFullScreen ? 0 : controlsHeight
        let screen = CGSize(width: space.width, height: space.height + top)
        let fit = FlipGeometry.fitSize(forFrontSize: frontPixelSize, flip: meta.flip, fitsFrontOnly: fitsFrontOnly)
        let scale = WatchCardInteraction.cornerClearanceScale(
            cardAspectRatio: fit.width / fit.height,
            restingBox: box,
            space: CGRect(origin: CGPoint(x: 0, y: top), size: space),
            screen: screen,
            cornerRadius: screen.width * WatchCardInteraction.screenCornerRadiusFraction
        )
        return CGSize(width: box.width * scale, height: box.height * scale)
    }

    // MARK: - Gestures

    /// A long press takes precedence over taps.
    private var longPressOrTap: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in onShowInfo() }
            .exclusively(before: SpatialTapGesture().onEnded { tap(at: $0.location) })
    }

    /// A single tap flips the card at once; a double tap takes that flip back and zooms in or
    /// out. While zoomed, a single tap does nothing.
    private func tap(at location: CGPoint) {
        switch taps.classify(at: ProcessInfo.processInfo.systemUptime, location: location) {
        case .single:
            hadFlippedBeforeTap = nil
            guard !isZoomed, isLoaded, hasBack else { return }
            hadFlippedBeforeTap = hasFlipped
            flip(halfTurns: 1)
        case .double:
            if let hadFlipped = hadFlippedBeforeTap {
                undoTapFlip(restoring: hadFlipped)
            }
            hadFlippedBeforeTap = nil
            toggleZoom()
        }
    }

    /// Takes back the flip a double tap's first tap began, as quickly as the zoom it's hidden
    /// under rather than in the flip's own time. A spring, because it takes over from the
    /// flip's in-flight animation, where a timing curve would run alongside it and let the
    /// flip carry on turning the card.
    private func undoTapFlip(restoring hadFlipped: Bool) {
        let undo = Animation.spring(duration: 0.25, bounce: 0)
        flipHalfTurnsAnimation = undo
        flipHalfTurns -= 1
        if hasFlipped != hadFlipped {
            withAnimation(undo) { hasFlipped = hadFlipped }
        }
    }

    /// Pans while zoomed. Otherwise the card follows a vertical drag part way, and once the
    /// drag ends, a sideways swipe flips the card and a vertical one pages through the
    /// collection — unless it's from the top, and hides or brings back the controls instead
    /// (`WatchCardInteraction.togglesFullScreen`), which the card doesn't follow. A drag that
    /// was neither lets the card settle back.
    private func swipeOrPan(in space: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if isZoomed {
                    let start = panAtDragStart ?? pan
                    panAtDragStart = start
                    pan = panBounds(in: space).rubberBanded(
                        CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height),
                        viewport: space
                    )
                } else if abs(value.translation.height) > abs(value.translation.width),
                          !togglesFullScreen(value.translation.height < 0 ? .up : .down, from: value.startLocation, in: space) {
                    pageDrag = WatchCardInteraction.pageDragOffset(
                        forVerticalTranslation: value.translation.height,
                        cardHeight: space.height
                    )
                } else if pageDrag != 0 {
                    withAnimation(.snappy) { pageDrag = 0 }
                }
            }
            .onEnded { value in
                guard !isZoomed else {
                    panAtDragStart = nil
                    let settled = panBounds(in: space).clamp(pan)
                    if settled != pan {
                        withAnimation(.spring(response: 0.35, dampingFraction: 1)) { pan = settled }
                    }
                    return
                }
                let direction = WatchCardInteraction.swipeDirection(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation
                )
                if let direction, togglesFullScreen(direction, from: value.startLocation, in: space) {
                    withAnimation(.snappy) {
                        pageDrag = 0
                        onFullScreen(!isFullScreen)
                    }
                    return
                }
                // One animation for both: the card slides back into its slot as the scroll
                // view moves on, so the page carries on from where the finger left it.
                withAnimation(.snappy) {
                    pageDrag = 0
                    if let direction, let step = WatchCardInteraction.pageStep(for: direction) {
                        onPage(step)
                    }
                }
                if let direction {
                    flip(direction)
                }
            }
    }

    private func togglesFullScreen(
        _ direction: WatchCardInteraction.SwipeDirection, from start: CGPoint, in space: CGSize
    ) -> Bool {
        WatchCardInteraction.togglesFullScreen(
            direction: direction, startY: start.y, spaceHeight: space.height, isFullScreen: isFullScreen
        )
    }

    /// Flips the card the way a sideways swipe went; a vertical one does nothing here. The
    /// first flip also zooms a card fitted by its front alone out to fit both sides, for good.
    private func flip(_ direction: WatchCardInteraction.SwipeDirection) {
        guard isLoaded, hasBack, let halfTurns = WatchCardInteraction.flipHalfTurns(for: direction) else { return }
        flip(halfTurns: halfTurns)
    }

    private func flip(halfTurns: Int) {
        // FlippableCardView animates its own angle to follow.
        flipHalfTurnsAnimation = nil
        flipHalfTurns += halfTurns
        if !hasFlipped {
            withAnimation(FlippableCardView.frontFitRelease) { hasFlipped = true }
        }
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

    /// How far the zoomed card may be panned, as on iPhone and Mac: a quarter of its showing face
    /// always stays on screen (see `ZoomGeometry.panBounds`).
    private func panBounds(in space: CGSize) -> ZoomGeometry.PanBounds {
        let face = WatchCardInteraction.visibleFaceSize(
            frontPixelSize: frontPixelSize,
            flip: meta.flip,
            fitsFrontOnly: fitsFrontOnly,
            showingFront: isShowingFront,
            fittedIn: restingSize(in: space)
        )
        // The watch lays the zoomed face out at full size rather than scaling it, so it's
        // measured at that size, centred, with no further scale.
        let zoomedFace = CGRect(
            x: (space.width - face.width * zoom) / 2,
            y: (space.height - face.height * zoom) / 2,
            width: face.width * zoom,
            height: face.height * zoom
        )
        return ZoomGeometry.panBounds(card: zoomedFace, viewport: space, scale: 1)
    }

    // MARK: - Loading

    private func loadScreenFaces() async {
        guard isReceived else {
            loadState = .waiting
            // Still missing after a while on screen — the queue hasn't reached this card, or
            // the person has scrolled ahead of it — so ask for it directly, and keep asking
            // (the library spaces the asks out) until it lands or the card leaves the screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.focusDelay)
                guard !Task.isCancelled else { return }
                library.requestFocus(id: collectionID, cardName: meta.name, tier: WatchRelay.tierScreen, sides: missingScreenSides)
            }
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

    /// While zoomed, swaps in the showing side's zoom face once it's here — asking the phone
    /// for it meanwhile, and again (the library spaces the asks out) until it lands or the
    /// card is zoomed back out.
    private func loadZoomFacesIfNeeded() async {
        let trigger = zoomLoadTrigger
        guard trigger.isZoomed else { return }
        guard trigger.hasZoomFace else {
            while !Task.isCancelled {
                library.requestFocus(id: collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, sides: [trigger.side])
                try? await Task.sleep(for: Self.focusDelay)
            }
            return
        }
        let isFront = trigger.side == WatchRelay.sideFront
        guard (isFront ? zoomFront : zoomBack) == nil, let image = await decodedZoomFace(side: trigger.side) else { return }
        guard !Task.isCancelled, isZoomed else { return }
        if isFront {
            zoomFront = image
        } else {
            zoomBack = image
        }
    }

    private func decodedZoomFace(side: String) async -> CGImage? {
        guard let url = library.cardBlobURL(collectionID, cardName: meta.name, tier: WatchRelay.tierZoom, side: side) else { return nil }
        return await library.decodedFaceCache.decodedFaceUncached(at: url)
    }
}
