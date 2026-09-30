import CoreGraphics
import Foundation

/// The pure decisions behind the watch card's gestures (see `WatchCardView`): which way a
/// swipe flips the card, which way a tap turns it, and how big the showing face is on screen —
/// kept free of SwiftUI so they're unit-testable.
enum WatchCardInteraction {
    enum SwipeDirection: Equatable {
        case left
        case right
    }

    /// How far a drag has to (be predicted to) travel sideways to count as a swipe.
    static let minimumSwipeDistance: CGFloat = 30

    /// Classifies a finished drag as a sideways swipe, or `nil` for anything too short or
    /// mostly vertical — vertical drags page through the collection. The predicted end
    /// translation stands in for velocity, so a short, quick flick counts as readily as a long
    /// drag; the mostly-sideways test uses the actual travel, which the prediction exaggerates.
    static func swipeDirection(translation: CGSize, predictedEndTranslation: CGSize) -> SwipeDirection? {
        let horizontal = abs(predictedEndTranslation.width) > abs(translation.width)
            ? predictedEndTranslation.width
            : translation.width
        guard abs(horizontal) >= minimumSwipeDistance else { return nil }
        guard abs(translation.width) > abs(translation.height) * 1.5 else { return nil }
        return horizontal > 0 ? .right : .left
    }

    /// The half turn a swipe adds to the flip: a rightward swipe turns the card by a positive
    /// angle, which (per `ParallaxGeometry`'s sign convention) sends its right edge away and
    /// brings its left edge forward and across to the right — the card turning the way the
    /// finger pushed it. Every flip axis but the calendar's has a vertical component, so this
    /// reads as a sideways turn; a calendar card still tumbles about its own top-to-bottom
    /// hinge, which is how that card physically turns over.
    static func flipHalfTurns(for direction: SwipeDirection) -> Int {
        direction == .right ? 1 : -1
    }

    /// The in-plane rotation a tap gives a card: a quarter turn toward the wearer's hand —
    /// the screen's right-hand side on a left wrist, its left on a right wrist, whichever way
    /// round the crown is. Raising that hand to hold the watch sideways brings that side to
    /// the top, so the card then reads upright, a landscape card filling the long side.
    static func quarterTurnDegrees(wornOnRightWrist: Bool) -> Double {
        wornOnRightWrist ? -90 : 90
    }

    /// The on-screen size of whichever face is showing, fitted into `available` the way
    /// `FlippableCardView` fits it: one scale for both faces, from their shared bounding box
    /// (turned with the card when it's a quarter turned). For clamping a zoomed card's pan to
    /// the card itself rather than to the screen.
    static func visibleFaceSize(
        frontPixelSize: CGSize,
        flip: Flip,
        showingFront: Bool,
        quarterTurned: Bool,
        fittedIn available: CGSize
    ) -> CGSize {
        guard frontPixelSize.width > 0, frontPixelSize.height > 0, available.width > 0, available.height > 0 else {
            return .zero
        }
        let bounding = FlipGeometry.boundingSize(forFrontSize: frontPixelSize, flip: flip)
        let turnedBounding = quarterTurned ? CGSize(width: bounding.height, height: bounding.width) : bounding
        let scale = min(available.width / turnedBounding.width, available.height / turnedBounding.height)
        let front = CGSize(width: frontPixelSize.width * scale, height: frontPixelSize.height * scale)
        let face = showingFront ? front : FlipGeometry.backSize(forFrontSize: front, flip: flip)
        return quarterTurned ? CGSize(width: face.height, height: face.width) : face
    }
}
