import CoreGraphics
import Foundation

/// Pure mapping from raw pointer/motion input to the small extra lean `ParallaxModel`
/// drives (see `FlippableCardView`'s second, additive `rotation3DEffect`). Kept free of
/// CoreMotion/AppKit/UIKit so clamping, centring, and sign behaviour can be unit tested
/// without a real device or window.
///
/// `x` is the tilt driven by horizontal input (device roll / horizontal pointer position),
/// applied by the view as a rotation about the vertical axis; `y` is driven by vertical
/// input (pitch / vertical pointer position), applied about the horizontal axis.
///
/// Sign convention (matching how `FlippableCardView` applies these about (0,1,0) and
/// (1,0,0) respectively): positive `x` recedes the card's RIGHT edge, positive `y` recedes
/// the card's TOP edge. Both mappings below are oriented so the two axes behave
/// consistently — the edge under the pointer recedes, and tilting the device's edge away
/// tilts the card's same edge away.
enum ParallaxGeometry {
    /// How far the card leans, in either axis. Small on purpose — this is a polish detail
    /// riding alongside the flip, not a replacement for it.
    static let maxDegrees: Double = 4

    struct Tilt: Equatable {
        var x: Double
        var y: Double
        static let zero = Tilt(x: 0, y: 0)
    }

    /// Maps a device attitude's pitch/roll DELTA (radians, current minus a slowly-decaying
    /// reference — see `ParallaxModel`) onto a clamped tilt: the card mimics the phone, so
    /// tilting a device edge away from the viewer tilts the card's same edge away.
    ///
    /// Pitch is NEGATED because CoreMotion's positive pitch brings the device's top edge
    /// toward the viewer, while positive `Tilt.y` recedes the card's top — without the
    /// flip, the vertical axis mirrors the device instead of following it (positive roll
    /// already moves the device's and card's right edges away together, no flip needed).
    static func tilt(pitchDelta: Double, rollDelta: Double, reduceMotion: Bool = false) -> Tilt {
        guard !reduceMotion else { return .zero }
        return Tilt(
            x: degrees(fromRadians: rollDelta).clamped(to: -maxDegrees...maxDegrees),
            y: degrees(fromRadians: -pitchDelta).clamped(to: -maxDegrees...maxDegrees)
        )
    }

    /// Maps a hover point within a view's bounds onto a clamped tilt: the centre is 0°,
    /// each edge (and beyond) is `maxDegrees`, and the edge under the pointer recedes.
    ///
    /// The vertical component is NEGATED (pointer above centre → positive `y`) because
    /// positive `Tilt.y` recedes the card's TOP edge while SwiftUI's y grows downward —
    /// without the flip, the top edge would come nearer under the pointer while the left
    /// and right edges recede, making the two axes feel inconsistent.
    ///
    /// `maxDegrees` defaults to the type's own constant (the card-detail flip's lean) but
    /// callers with a smaller/subtler use in mind — e.g. grid thumbnail hover — can pass a
    /// reduced cap; the mapping and clamping behaviour are otherwise identical.
    static func tilt(hoverLocation: CGPoint, in size: CGSize, reduceMotion: Bool = false, maxDegrees: Double = Self.maxDegrees) -> Tilt {
        guard !reduceMotion, size.width > 0, size.height > 0 else { return .zero }
        let normalizedX = (hoverLocation.x / size.width) * 2 - 1
        let normalizedY = (hoverLocation.y / size.height) * 2 - 1
        return Tilt(
            x: normalizedX.clamped(to: -1...1) * maxDegrees,
            y: -normalizedY.clamped(to: -1...1) * maxDegrees
        )
    }

    /// Eases a reference value a `factor` fraction of the way toward `current` (0 = doesn't
    /// move, 1 = jumps straight there). Used to slowly re-centre the device-motion
    /// reference attitude so holding the phone at a steady angle doesn't pin the tilt off
    /// to one side forever, without ever visibly snapping.
    static func decay(reference: Double, towardCurrent current: Double, factor: Double) -> Double {
        reference + (current - reference) * factor
    }

    private static func degrees(fromRadians radians: Double) -> Double {
        radians * 180 / .pi
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
