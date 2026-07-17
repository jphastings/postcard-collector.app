import CoreGraphics
import Foundation

/// A user-drawn rectangular "secret" area on one side of a postcard-in-progress: erased and
/// protected by the compile pipeline (`types.Polygon`'s box form — see dotpostcard's
/// `types/secrets.go`). `rect` is normalized 0–1 in image space (origin top-left, matching
/// ImageIO's row order), independent of whatever size the editor happens to display the
/// image at — see `viewRect(ofNormalized:displaySize:)`/`normalizedRect(ofView:displaySize:)`
/// for converting to and from the editor's on-screen coordinates.
struct SecretRegion: Identifiable, Hashable, Sendable {
    /// The eight drag handles a selected region exposes for resizing: the four corners plus
    /// the midpoint of each edge.
    enum Handle: CaseIterable, Hashable, Sendable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        /// This handle's position within a rect, as a fraction of its width/height (0...1 on
        /// each axis).
        var fraction: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0)
            case .top: CGPoint(x: 0.5, y: 0)
            case .topRight: CGPoint(x: 1, y: 0)
            case .left: CGPoint(x: 0, y: 0.5)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottomLeft: CGPoint(x: 0, y: 1)
            case .bottom: CGPoint(x: 0.5, y: 1)
            case .bottomRight: CGPoint(x: 1, y: 1)
            }
        }

        // Not fileprivate: besides driving `applying(delta:to:of:)` below, the editor's loupe
        // reuses these directly to decide which of a resize's edges to draw heavier (the
        // left/top/right/bottom edges are exactly the min/max X/Y edges in this same
        // top-left-origin image space).
        var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesMinY: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesMaxY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    let id: UUID
    var rect: CGRect
    /// "Already hidden in scan" — the region should still be recorded (so the format's
    /// intent is documented and the area stays protected from any future re-processing),
    /// but the compile pipeline doesn't need to erase pixels that are already blank/redacted.
    var prehidden: Bool

    /// Rects are clamped on construction (see `clamped(_:)`) so every `SecretRegion` in play
    /// is always valid — callers never need to re-check bounds before using one.
    init(id: UUID = UUID(), rect: CGRect, prehidden: Bool = false) {
        self.id = id
        self.rect = SecretRegion.clamped(rect)
        self.prehidden = prehidden
    }
}

extension SecretRegion {
    /// The smallest a region may be along either axis, in normalized units — small enough to
    /// cover a postmark corner, large enough that its handles stay individually grabbable.
    static let minimumDimension: CGFloat = 0.02

    /// Clamps `rect` to the unit square and to `minimumDimension`, standardizing a
    /// negative-size rect (e.g. the result of a right-to-left or bottom-to-top drag) first.
    static func clamped(_ rect: CGRect) -> CGRect {
        let standardized = rect.standardized
        let width = min(max(standardized.width, minimumDimension), 1)
        let height = min(max(standardized.height, minimumDimension), 1)
        let x = min(max(standardized.minX, 0), 1 - width)
        let y = min(max(standardized.minY, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Resizes `rect` by dragging `handle`: moves whichever edges that handle owns by `delta`
    /// (normalized units, the same space as `rect`), then re-clamps — so a drag that
    /// overshoots the opposite edge or the unit square collapses to the minimum size instead
    /// of inverting.
    static func applying(delta: CGVector, to handle: Handle, of rect: CGRect) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if handle.movesMinX { minX += delta.dx }
        if handle.movesMaxX { maxX += delta.dx }
        if handle.movesMinY { minY += delta.dy }
        if handle.movesMaxY { maxY += delta.dy }
        return clamped(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }

    /// Converts a normalized (0–1) rect into view-space points for an image displayed at
    /// `displaySize`.
    static func viewRect(ofNormalized rect: CGRect, displaySize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * displaySize.width,
            y: rect.minY * displaySize.height,
            width: rect.width * displaySize.width,
            height: rect.height * displaySize.height
        )
    }

    /// The inverse of `viewRect(ofNormalized:displaySize:)`.
    static func normalizedRect(ofView rect: CGRect, displaySize: CGSize) -> CGRect {
        guard displaySize.width > 0, displaySize.height > 0 else { return .zero }
        return CGRect(
            x: rect.minX / displaySize.width,
            y: rect.minY / displaySize.height,
            width: rect.width / displaySize.width,
            height: rect.height / displaySize.height
        )
    }

    /// The single-point form of `normalizedRect(ofView:displaySize:)` — the editor's loupe
    /// uses this to turn the active drag point into the 0–1 image-space center `LoupeGeometry`
    /// needs, without duplicating the division inline.
    static func normalizedPoint(ofView point: CGPoint, displaySize: CGSize) -> CGPoint {
        guard displaySize.width > 0, displaySize.height > 0 else { return .zero }
        return CGPoint(x: point.x / displaySize.width, y: point.y / displaySize.height)
    }

    /// The handle nearest `point` (in view space), if any lies within `tolerance` points —
    /// used by the editor to decide whether a press starts a resize, and which handle it
    /// grabbed. `nil` means the press should be treated as something else (a move, or the
    /// start of a new region).
    func handle(at point: CGPoint, displaySize: CGSize, tolerance: CGFloat) -> Handle? {
        let view = SecretRegion.viewRect(ofNormalized: rect, displaySize: displaySize)
        return Handle.allCases
            .map { handle -> (Handle, CGFloat) in
                let position = CGPoint(x: view.minX + handle.fraction.x * view.width, y: view.minY + handle.fraction.y * view.height)
                return (handle, hypot(point.x - position.x, point.y - position.y))
            }
            .filter { $0.1 <= tolerance }
            .min { $0.1 < $1.1 }?
            .0
    }
}

extension SecretRegion {
    /// Translates `rect` by `delta` (normalized units) without resizing it, clamping the
    /// result's position (not its size, which is assumed already valid) to the unit square —
    /// the editor's "drag inside a region moves it" behavior.
    static func moved(_ rect: CGRect, by delta: CGVector) -> CGRect {
        let width = min(rect.width, 1)
        let height = min(rect.height, 1)
        let x = min(max(rect.minX + delta.dx, 0), 1 - width)
        let y = min(max(rect.minY + delta.dy, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The rectangle spanning two view-space points, regardless of which corner the drag
    /// started or ended at — the editor's rubber-band preview while a create-drag is in
    /// progress. Not clamped/minimum-sized; that happens for free when the caller passes the
    /// normalized result into `SecretRegion.init`.
    static func rubberBand(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Where a `contentSize`-shaped image sits when displayed with `scaledToFit` inside a
    /// larger `containerSize` — the letterboxed sub-rect `viewRect(ofNormalized:displaySize:)`
    /// (whose `displaySize` is the FITTED size alone) needs offsetting into, since SwiftUI's
    /// `scaledToFit` centers content within its container without shrinking the container's
    /// own reported layout size. Used both by the editor (fitting the full image in its
    /// canvas) and by `PostcardStage`'s thumbnail secret-outline overlay (fitting the
    /// decoded thumbnail in its side card).
    static func fittedFrame(ofContentSize contentSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / contentSize.width, containerSize.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    /// Maps a raw gesture point — reported in the editor's outer, untransformed container
    /// (see the "attach gestures to an untransformed container" rule this codebase has paid
    /// for; `CardDetailView`'s own zoom/pan does the same) — into display space, the
    /// coordinate space `viewRect(ofNormalized:displaySize:)`/`normalizedRect(ofView:displaySize:)`
    /// use. Inverts the same "scale, then offset, both anchored at the container's own
    /// center" model `ZoomGeometry` assumes for its own anchor math, then un-letterboxes by
    /// `displayFrame`'s origin. `displayFrame` is the fitted image's frame WITHIN that
    /// container (see `fittedFrame(ofContentSize:in:)`) at zoomScale 1 — the container itself
    /// is what's actually scaled/offset, so `displayFrame` never changes with zoom.
    static func displayPoint(
        ofContainerPoint point: CGPoint,
        containerSize: CGSize,
        displayFrame: CGRect,
        zoomScale: CGFloat,
        zoomOffset: CGSize
    ) -> CGPoint {
        guard zoomScale != 0 else { return .zero }
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        let unscaled = CGPoint(
            x: center.x + (point.x - center.x - zoomOffset.width) / zoomScale,
            y: center.y + (point.y - center.y - zoomOffset.height) / zoomScale
        )
        return CGPoint(x: unscaled.x - displayFrame.minX, y: unscaled.y - displayFrame.minY)
    }

    /// The inverse of `displayPoint(ofContainerPoint:containerSize:displayFrame:zoomScale:zoomOffset:)`
    /// — where a display-space point currently renders on screen, e.g. so the editor's loupe
    /// (drawn OUTSIDE the zoomed/panned content, at a constant size) can float above the
    /// precise point being dragged regardless of the current zoom/pan.
    static func containerPoint(
        ofDisplayPoint point: CGPoint,
        containerSize: CGSize,
        displayFrame: CGRect,
        zoomScale: CGFloat,
        zoomOffset: CGSize
    ) -> CGPoint {
        let center = CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        let unscaled = CGPoint(x: point.x + displayFrame.minX, y: point.y + displayFrame.minY)
        return CGPoint(
            x: center.x + zoomOffset.width + zoomScale * (unscaled.x - center.x),
            y: center.y + zoomOffset.height + zoomScale * (unscaled.y - center.y)
        )
    }
}

/// Pure geometry for `SecretRegionEditor`'s loupe: what square of the source image to crop
/// and magnify, and where on screen to float the circular result — kept alongside
/// `SecretRegion`'s other editor geometry so none of it needs computing in the view.
enum LoupeGeometry {
    /// The square region (in image PIXEL coordinates, origin top-left — matching
    /// `SecretRegion`'s own convention) a loupe should crop and magnify, centered on
    /// `normalizedCenter` (0–1, image space) at `pixelMagnification` screen-points-per-source-
    /// pixel, sized so the crop exactly fills a `loupeDiameter`-point circle once scaled up.
    /// Clamped to the image's own pixel bounds so a center near an edge slides the crop
    /// inward instead of sampling off-image. `pixelMagnification` is normally
    /// `effectiveMagnification(_:zoomScale:imagePixelSize:displaySize:)`'s output, not a bare
    /// "3×" — see that function for why.
    static func sourceRect(normalizedCenter: CGPoint, imagePixelSize: CGSize, loupeDiameter: CGFloat, pixelMagnification: CGFloat) -> CGRect {
        guard pixelMagnification > 0, imagePixelSize.width > 0, imagePixelSize.height > 0 else {
            return CGRect(origin: .zero, size: imagePixelSize)
        }
        let side = min(loupeDiameter / pixelMagnification, min(imagePixelSize.width, imagePixelSize.height))
        let center = CGPoint(x: normalizedCenter.x * imagePixelSize.width, y: normalizedCenter.y * imagePixelSize.height)
        let x = min(max(center.x - side / 2, 0), imagePixelSize.width - side)
        let y = min(max(center.y - side / 2, 0), imagePixelSize.height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Converts a "show `magnification`× what's already visible on screen" request (the
    /// design intent — "a zoomed ~3× crop") into the screen-points-per-source-pixel value
    /// `sourceRect` needs. Folds in the canvas's own current pinch `zoomScale` and the
    /// image's native-pixel-to-display-point ratio, so the loupe's apparent magnification
    /// stays relative to what the user currently sees — without this, a high-DPI scan fitted
    /// small on screen would make a bare "3×" crop just a few dozen source pixels wide: fine
    /// detail, but too tight to recognize what's being covered.
    static func effectiveMagnification(_ magnification: CGFloat, zoomScale: CGFloat, imagePixelSize: CGSize, displaySize: CGSize) -> CGFloat {
        guard imagePixelSize.width > 0 else { return magnification }
        return magnification * zoomScale * displaySize.width / imagePixelSize.width
    }

    /// Maps a region's rect (normalized 0–1 image space, `SecretRegion.rect`'s own convention)
    /// into the loupe-space points its cropped image is drawn into: `sourceRect`'s origin is
    /// subtracted first (so a region's position is relative to the crop, not the whole image),
    /// then the result is scaled by `pixelMagnification` — the same factor that turns
    /// `sourceRect`'s pixels into the loupe's on-screen circle. Not clamped to the loupe's own
    /// bounds — a region only partially (or not at all) within `sourceRect` maps to a rect
    /// that extends outside `0..<diameter`; the caller's circular `Canvas` clip takes care of
    /// showing only the visible portion, so the active region's edge/corner reads correctly
    /// even mid-drag when it may briefly leave the crop.
    static func magnifiedRect(ofNormalized rect: CGRect, imagePixelSize: CGSize, sourceRect: CGRect, pixelMagnification: CGFloat) -> CGRect {
        let pixelRect = CGRect(
            x: rect.minX * imagePixelSize.width,
            y: rect.minY * imagePixelSize.height,
            width: rect.width * imagePixelSize.width,
            height: rect.height * imagePixelSize.height
        )
        return CGRect(
            x: (pixelRect.minX - sourceRect.minX) * pixelMagnification,
            y: (pixelRect.minY - sourceRect.minY) * pixelMagnification,
            width: pixelRect.width * pixelMagnification,
            height: pixelRect.height * pixelMagnification
        )
    }

    /// Where to center a `diameter`-wide circular loupe, floating above `point` (both in the
    /// same container-local space) by `diameter / 2 + gap` so it hovers clear of the
    /// finger/cursor, but pinned to stay fully inside `containerSize` on every edge rather
    /// than clipping — nearest the top edge this means the loupe sits over the touch point
    /// instead of off-screen, which is preferable to being invisible.
    static func position(for point: CGPoint, containerSize: CGSize, diameter: CGFloat, gap: CGFloat = 16) -> CGPoint {
        let radius = diameter / 2
        let preferredY = point.y - radius - gap
        let y = min(max(preferredY, radius), max(containerSize.height - radius, radius))
        let x = min(max(point.x, radius), max(containerSize.width - radius, radius))
        return CGPoint(x: x, y: y)
    }
}
