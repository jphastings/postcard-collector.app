import CoreGraphics
import Foundation

/// The pure decisions behind the watch card's gestures (see `WatchCardView`): what a finished
/// drag was — a sideways swipe flips the card, a vertical one pages through the collection,
/// unless it's from the top edge and hides or brings back the controls — whether a tap was
/// single or double, how far the card follows a vertical drag while it's in progress, how big
/// the showing face is on screen, and how much a resting card shrinks to keep its corners off
/// the screen's curved ones.
/// Kept free of SwiftUI so they're unit-testable.
enum WatchCardInteraction {
    enum SwipeDirection: Equatable {
        case left
        case right
        case up
        case down
    }

    /// How far a drag has to (be predicted to) travel to count as a swipe.
    static let minimumSwipeDistance: CGFloat = 30

    /// Classifies a finished drag as a swipe, or `nil` for anything too short or too diagonal
    /// to call. A sideways swipe must be clearly sideways — flipping the card by accident is
    /// more jarring than missing a page — while a vertical one only has to be more vertical
    /// than not. The predicted end translation stands in for velocity, so a short, quick flick
    /// counts as readily as a long drag; which way the drag went is judged on the actual
    /// travel, which the prediction exaggerates.
    static func swipeDirection(translation: CGSize, predictedEndTranslation: CGSize) -> SwipeDirection? {
        if abs(translation.width) > abs(translation.height) * 1.5 {
            let horizontal = furthest(translation.width, predictedEndTranslation.width)
            guard abs(horizontal) >= minimumSwipeDistance else { return nil }
            return horizontal > 0 ? .right : .left
        }
        if abs(translation.height) > abs(translation.width) {
            let vertical = furthest(translation.height, predictedEndTranslation.height)
            guard abs(vertical) >= minimumSwipeDistance else { return nil }
            return vertical < 0 ? .up : .down
        }
        return nil
    }

    private static func furthest(_ actual: CGFloat, _ predicted: CGFloat) -> CGFloat {
        abs(predicted) > abs(actual) ? predicted : actual
    }

    /// The half turn a sideways swipe adds to the flip, or `nil` for a vertical one. A
    /// rightward swipe turns the card by a positive angle, which (per `ParallaxGeometry`'s sign
    /// convention) sends its right edge away and brings its left edge forward and across to the
    /// right — the card turning the way the finger pushed it. Every flip axis but the
    /// calendar's has a vertical component, so this reads as a sideways turn; a calendar card
    /// still tumbles about its own top-to-bottom hinge, which is how that card physically turns
    /// over.
    static func flipHalfTurns(for direction: SwipeDirection) -> Int? {
        switch direction {
        case .right: 1
        case .left: -1
        case .up, .down: nil
        }
    }

    /// How many cards a vertical swipe moves through the collection, or `nil` for a sideways
    /// one: swiping up pushes the card up and away to bring in the next, as the crown does
    /// turning forward.
    static func pageStep(for direction: SwipeDirection) -> Int? {
        switch direction {
        case .up: 1
        case .down: -1
        case .left, .right: nil
        }
    }

    /// The card `step` places on from `cardID` in `cardIDs` (the collection's display order),
    /// or `nil` past either end — or if `cardID` isn't among them.
    static func pageTarget(from cardID: String, step: Int, in cardIDs: [String]) -> String? {
        guard let index = cardIDs.firstIndex(of: cardID) else { return nil }
        let target = index + step
        return cardIDs.indices.contains(target) ? cardIDs[target] : nil
    }

    /// How far the card follows a vertical drag while it's still in progress: a fraction of
    /// the finger's travel, up to a quarter of the card's height — enough to show the swipe has
    /// hold of the card, without opening a wide gap where the next card will slide in.
    static func pageDragOffset(forVerticalTranslation translation: CGFloat, cardHeight: CGFloat) -> CGFloat {
        let limit = max(cardHeight, 0) / 4
        return min(max(translation * 0.4, -limit), limit)
    }

    // MARK: - Taps

    /// Tells single taps from double ones as each lands, so a single tap can act at once
    /// instead of waiting out the double-tap window. A tap is the second of a double if it
    /// lands soon after, and near, the previous *single* tap; a double resets the sequence, so
    /// a third tap starts afresh.
    struct TapSequence {
        enum Tap: Equatable {
            case single
            case double
        }

        /// Measured between the taps' ends, so it includes the second tap's own touch.
        static let doubleTapInterval: TimeInterval = 0.35
        static let doubleTapDistance: CGFloat = 40

        private var lastSingle: (time: TimeInterval, location: CGPoint)?

        mutating func classify(at time: TimeInterval, location: CGPoint) -> Tap {
            if let last = lastSingle,
               time - last.time <= Self.doubleTapInterval,
               hypot(location.x - last.location.x, location.y - last.location.y) <= Self.doubleTapDistance {
                lastSingle = nil
                return .double
            }
            lastSingle = (time, location)
            return .single
        }
    }

    // MARK: - Full screen

    /// How far down the card's space, as a fraction of its height, a vertical swipe can start
    /// and still count as one from the top edge (see `togglesFullScreen`).
    static let topEdgeFraction: CGFloat = 0.25

    /// Whether a vertical swipe hides or brings back the collection's controls (its back button
    /// and title) instead of paging: one starting at the top of the card's space that pushes up
    /// while they're showing, off the top of the screen, or pulls down while they're hidden.
    /// Any other vertical swipe pages, including one from the top that pushes the way they
    /// already are. `startY` is measured from the top of the card's space, which starts below
    /// the controls while they're showing and at the top of the screen once they're not.
    static func togglesFullScreen(
        direction: SwipeDirection,
        startY: CGFloat,
        spaceHeight: CGFloat,
        isFullScreen: Bool
    ) -> Bool {
        guard spaceHeight > 0, startY <= spaceHeight * topEdgeFraction else { return false }
        switch direction {
        case .up: return !isFullScreen
        case .down: return isFullScreen
        case .left, .right: return false
        }
    }

    // MARK: - Screen corners

    /// The watch screen's corner radius as a fraction of its width. Measured from the 46mm
    /// Series 12 simulator's screen mask (208×248pt): a continuous corner that sits just inside
    /// a circular arc of about 55pt.
    static let screenCornerRadiusFraction: CGFloat = 0.264
    /// How far inside the screen's curved corners a card's corners keep.
    static let screenCornerMargin: CGFloat = 2

    /// The scale (at most 1) to apply to `restingBox` so a card of `cardAspectRatio`, fitted
    /// into it and centred in `space` (in screen coordinates), keeps its corners inside the
    /// screen's rounded corners. Cards whose corners already clear them come back at 1.
    static func cornerClearanceScale(
        cardAspectRatio: CGFloat,
        restingBox: CGSize,
        space: CGRect,
        screen: CGSize,
        cornerRadius: CGFloat,
        margin: CGFloat = screenCornerMargin
    ) -> CGFloat {
        guard cardAspectRatio.isFinite, cardAspectRatio > 0, restingBox.width > 0, restingBox.height > 0 else { return 1 }
        let width = min(restingBox.width, restingBox.height * cardAspectRatio)
        let half = CGSize(width: width / 2, height: width / cardAspectRatio / 2)
        func clears(_ scale: CGFloat) -> Bool {
            [(-1, -1), (1, -1), (-1, 1), (1, 1)].allSatisfy { (dx: CGFloat, dy: CGFloat) in
                isInsideScreenCorners(
                    CGPoint(x: space.midX + dx * half.width * scale, y: space.midY + dy * half.height * scale),
                    screen: screen, cornerRadius: cornerRadius, margin: margin
                )
            }
        }
        guard !clears(1) else { return 1 }
        // `clear` only ever holds a scale that clears, so a near miss errs small, never clipped.
        var clear: CGFloat = 0
        var clipped: CGFloat = 1
        for _ in 0..<24 {
            let mid = (clear + clipped) / 2
            if clears(mid) { clear = mid } else { clipped = mid }
        }
        return clear
    }

    /// Whether an on-screen point is clear of the screen's curved corners (by `margin`). The
    /// straight edges get no margin: a resting card runs right up to them.
    private static func isInsideScreenCorners(
        _ point: CGPoint, screen: CGSize, cornerRadius: CGFloat, margin: CGFloat
    ) -> Bool {
        let centre = CGPoint(
            x: min(max(point.x, cornerRadius), screen.width - cornerRadius),
            y: min(max(point.y, cornerRadius), screen.height - cornerRadius)
        )
        guard centre.x != point.x, centre.y != point.y else { return true }
        return hypot(point.x - centre.x, point.y - centre.y) <= cornerRadius - margin
    }

    /// The on-screen size of whichever face is showing, fitted into `available` the way
    /// `FlippableCardView` fits it: one scale for both faces, from their shared bounding box —
    /// or from the front alone, while `fitsFrontOnly`. For clamping a zoomed card's pan to the
    /// card itself rather than to the screen.
    static func visibleFaceSize(
        frontPixelSize: CGSize,
        flip: Flip,
        fitsFrontOnly: Bool = false,
        showingFront: Bool,
        fittedIn available: CGSize
    ) -> CGSize {
        guard frontPixelSize.width > 0, frontPixelSize.height > 0, available.width > 0, available.height > 0 else {
            return .zero
        }
        let bounding = FlipGeometry.fitSize(forFrontSize: frontPixelSize, flip: flip, fitsFrontOnly: fitsFrontOnly)
        let scale = min(available.width / bounding.width, available.height / bounding.height)
        let front = CGSize(width: frontPixelSize.width * scale, height: frontPixelSize.height * scale)
        return showingFront ? front : FlipGeometry.backSize(forFrontSize: front, flip: flip)
    }
}
