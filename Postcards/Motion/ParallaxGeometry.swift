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
    /// reference — see `ParallaxModel`) onto a clamped tilt.
    static func tilt(pitchDelta: Double, rollDelta: Double, reduceMotion: Bool = false) -> Tilt {
        guard !reduceMotion else { return .zero }
        return Tilt(
            x: degrees(fromRadians: rollDelta).clamped(to: -maxDegrees...maxDegrees),
            y: degrees(fromRadians: pitchDelta).clamped(to: -maxDegrees...maxDegrees)
        )
    }

    /// Maps a hover point within a view's bounds onto a clamped tilt: the centre is 0°,
    /// each edge (and beyond) is `maxDegrees`. Pointer right of centre tilts positive in x;
    /// pointer below centre (SwiftUI's y grows downward) tilts positive in y.
    static func tilt(hoverLocation: CGPoint, in size: CGSize, reduceMotion: Bool = false) -> Tilt {
        guard !reduceMotion, size.width > 0, size.height > 0 else { return .zero }
        let normalizedX = (hoverLocation.x / size.width) * 2 - 1
        let normalizedY = (hoverLocation.y / size.height) * 2 - 1
        return Tilt(
            x: normalizedX.clamped(to: -1...1) * maxDegrees,
            y: normalizedY.clamped(to: -1...1) * maxDegrees
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
