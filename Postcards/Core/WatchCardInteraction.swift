import CoreGraphics
import Foundation

/// The pure decisions behind the watch card's gestures (see `WatchCardView`): what a finished
/// drag was — a sideways swipe flips the card, a vertical one pages through the collection —
/// how far the card follows a vertical drag while it's in progress, and how big the showing
/// face is on screen. Kept free of SwiftUI so they're unit-testable.
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

    /// The on-screen size of whichever face is showing, fitted into `available` the way
    /// `FlippableCardView` fits it: one scale for both faces, from their shared bounding box.
    /// For clamping a zoomed card's pan to the card itself rather than to the screen.
    static func visibleFaceSize(
        frontPixelSize: CGSize,
        flip: Flip,
        showingFront: Bool,
        fittedIn available: CGSize
    ) -> CGSize {
        guard frontPixelSize.width > 0, frontPixelSize.height > 0, available.width > 0, available.height > 0 else {
            return .zero
        }
        let bounding = FlipGeometry.boundingSize(forFrontSize: frontPixelSize, flip: flip)
        let scale = min(available.width / bounding.width, available.height / bounding.height)
        let front = CGSize(width: frontPixelSize.width * scale, height: frontPixelSize.height * scale)
        return showingFront ? front : FlipGeometry.backSize(forFrontSize: front, flip: flip)
    }
}
