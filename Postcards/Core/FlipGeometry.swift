import CoreGraphics
import Foundation

/// A 3D rotation axis, mirroring the `(x, y, z)` triples SwiftUI's
/// `rotation3DEffect(_:axis:)` takes. Kept as a plain value type (rather than importing
/// SwiftUI here) so the axis-mapping table can be unit tested without pulling in UIKit/AppKit.
struct FlipAxis: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
}

extension Flip {
    /// Mirrors `types.Flip.IsHeteroriented` in the Go core: hand flips join a landscape
    /// side to a portrait one, so the back reads 90°-rotated relative to the front.
    var isHeteroriented: Bool { self == .leftHand || self == .rightHand }
}

/// Derives the 3D tap-to-flip geometry for each `Flip` type, from the reference CSS
/// implementation at `formats/web/postcards.css` in the Go core repo:
///
/// - `book`      → `rotateY`               → axis (0, 1, 0)
/// - `calendar`  → `rotateX`               → axis (1, 0, 0)
/// - `right-hand`→ `rotate3d(1, 1, 0, …)`  → axis (1, 1, 0)
/// - `left-hand` → `rotate3d(-1, 1, 0, …)` → axis (-1, 1, 0)
/// - `none`      → no flip                 → no axis
///
/// Unlike the CSS (which masks the single un-split combined image and so also needs an
/// extra flat `rotate(±90deg)` on the back face), `ImageSplitter` already bakes the
/// hand-flip un-rotation into the back `CGImage` pixel data before this ever runs. So the
/// back face here only needs an extra 180° added to the same 3D axis — no 2D pre-rotation.
enum FlipGeometry {
    static func axis(for flip: Flip) -> FlipAxis? {
        switch flip {
        case .book: return FlipAxis(x: 0, y: 1, z: 0)
        case .calendar: return FlipAxis(x: 1, y: 0, z: 0)
        case .rightHand: return FlipAxis(x: 1, y: 1, z: 0)
        case .leftHand: return FlipAxis(x: -1, y: 1, z: 0)
        case .none: return nil
        }
    }

    /// Whether a face rotated by `angleDegrees` points towards the viewer. A physical
    /// card's side is visible if and only if its face normal faces the viewer — a strict
    /// step function of the angle that cuts hard at the edge-on moments (90°, 270°, …),
    /// which is exactly the sign of cos. Works for negative and multi-revolution angles
    /// (the tap gesture accumulates +180° indefinitely), since cos is periodic.
    ///
    /// `FlipFace` feeds this the LIVE animated angle every frame (via `Animatable`), so
    /// during a flip the visibility switch lands mid-animation at 90° with no fading.
    static func showsFront(atDegrees angleDegrees: Double) -> Bool {
        cos(angleDegrees * .pi / 180) > 0
    }

    /// The back's display size given the front's. Both sides are the same physical piece
    /// of card, so a hand flip's back — which reads 90°-rotated — must display with the
    /// dimensions swapped at identical scale (and therefore identical area): the 180° turn
    /// about the diagonal axis carries one rectangle exactly onto the other.
    static func backSize(forFrontSize size: CGSize, flip: Flip) -> CGSize {
        flip.isHeteroriented ? CGSize(width: size.height, height: size.width) : size
    }

    /// The bounding box that both resting orientations fit inside: for hand flips the
    /// union of W×H and H×W centred on the same point is a square of side max(W, H) —
    /// which is what the reference CSS's `aspect-ratio: 1/1` container reserves — and for
    /// everything else it's just the front's own size.
    static func boundingSize(forFrontSize size: CGSize, flip: Flip) -> CGSize {
        guard flip.isHeteroriented else { return size }
        let side = max(size.width, size.height)
        return CGSize(width: side, height: side)
    }

    // MARK: - The stage's flip-axis demo

    /// The flip angle for `FlipAxisDemo`'s never-pausing rotation: 360° every `period`
    /// seconds, as a pure function of elapsed time so `TimelineView(.animation)` never needs
    /// to store or animate any state itself — each tick just re-evaluates this. Periodic and
    /// well-defined for any `elapsedSeconds` (negative included), matching
    /// `showsFront(atDegrees:)`'s own tolerance for angles outside one revolution.
    static func continuousAngleDegrees(elapsedSeconds: TimeInterval, period: TimeInterval) -> Double {
        guard period > 0 else { return 0 }
        let phase = elapsedSeconds.truncatingRemainder(dividingBy: period) / period
        return phase * 360
    }

    /// The two endpoints of the dotted axis line drawn behind `FlipAxisDemo`, in a
    /// `boxSide`×`boxSide` square (origin top-left): the hinge direction (`axis.x`, `axis.y`)
    /// extended out from the centre until it meets the square's edge — a vertical line for
    /// book, horizontal for calendar, and a corner-to-corner diagonal for either hand flip.
    static func axisLineEndpoints(axis: FlipAxis, boxSide: CGFloat) -> (start: CGPoint, end: CGPoint) {
        let half = boxSide / 2
        let center = CGPoint(x: half, y: half)
        let dx = CGFloat(axis.x)
        let dy = CGFloat(axis.y)
        guard dx != 0 || dy != 0 else { return (center, center) }
        let scale = half / max(abs(dx), abs(dy))
        let offset = CGPoint(x: dx * scale, y: dy * scale)
        return (
            CGPoint(x: half - offset.x, y: half - offset.y),
            CGPoint(x: half + offset.x, y: half + offset.y)
        )
    }
}
