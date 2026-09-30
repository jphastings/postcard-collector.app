import CoreGraphics

/// Pure geometry for pinch-to-zoom-at-a-point (`CardDetailView`'s `magnifyGesture`): keeps
/// whatever content point was under the pinch/cursor fixed on screen as scale changes, by
/// solving for the pan offset that cancels out the anchor point's apparent movement.
///
/// For content scaled around its own center and then panned by `offset`, a content point
/// `P`'s screen position is `center + offset + scale * (P - center)`. Holding that
/// constant while `scale` changes and solving for the new `offset` gives the formula below.
/// `anchor` and `contentSize` must both be in the SAME unscaled, unpanned coordinate space
/// (e.g. captured before `.scaleEffect`/`.offset` are applied) — mixing a post-transform
/// gesture location with a pre-transform size is what makes the anchor drift instead of
/// holding still. A gesture's own location is on screen, so turn it into that space with
/// `contentPoint(atScreenPoint:…)` first: the two only coincide at rest (scale 1, no pan).
enum ZoomGeometry {
    /// The content point (in the unscaled, unpanned space `offset(keepingAnchor:…)` takes)
    /// currently shown at `screenPoint`, for content scaled by `scale` about its centre and
    /// then panned by `offset` — the inverse of `center + offset + scale * (P - center)`.
    static func contentPoint(
        atScreenPoint screenPoint: CGPoint,
        inContentOfSize contentSize: CGSize,
        scale: CGFloat,
        offset: CGSize
    ) -> CGPoint {
        let center = CGPoint(x: contentSize.width / 2, y: contentSize.height / 2)
        let scale = max(scale, .ulpOfOne)
        return CGPoint(
            x: center.x + (screenPoint.x - center.x - offset.width) / scale,
            y: center.y + (screenPoint.y - center.y - offset.height) / scale
        )
    }

    /// The scale to show for a pinch that's asking for `proposed`: `proposed` itself within
    /// `range`, and beyond it only `resistance` of the overshoot — the give that says you've
    /// reached the end, rather than a hard stop, which the pinch's end then settles back into
    /// `range`. Never below 0.
    static func resistedScale(_ proposed: CGFloat, within range: ClosedRange<CGFloat>, resistance: CGFloat = 0.3) -> CGFloat {
        if proposed < range.lowerBound {
            return max(range.lowerBound - (range.lowerBound - proposed) * resistance, 0)
        }
        if proposed > range.upperBound {
            return range.upperBound + (proposed - range.upperBound) * resistance
        }
        return proposed
    }

    static func offset(
        keepingAnchor anchor: CGPoint,
        inContentOfSize contentSize: CGSize,
        previousScale: CGFloat,
        previousOffset: CGSize,
        newScale: CGFloat
    ) -> CGSize {
        let anchorFromCenter = CGVector(
            dx: anchor.x - contentSize.width / 2,
            dy: anchor.y - contentSize.height / 2
        )
        return CGSize(
            width: previousOffset.width - (newScale - previousScale) * anchorFromCenter.dx,
            height: previousOffset.height - (newScale - previousScale) * anchorFromCenter.dy
        )
    }

    /// Clamps the pan offset of `contentSize`-sized content, centred in a
    /// `containerSize`-sized viewport, so it can never be dragged far enough to open a gap at
    /// an edge it overflows: the bound on each axis is half the overhang,
    /// `(content - container) / 2`, and content that fits on an axis stays centred on it.
    /// Unlike `CardDetailView`'s free-panning pinch zoom, the watch's double-tap zoom
    /// (`WatchCardView`, passing the zoomed card's own size) needs its pan clamped, since it
    /// sits inside a snap-scrolling list that only disables paging while zoomed — an unclamped
    /// drag could otherwise shove the whole card out of view with no way back short of the
    /// zoom-reset gesture.
    static func clampedOffset(_ offset: CGSize, contentSize: CGSize, containerSize: CGSize) -> CGSize {
        let maxX = max(0, (contentSize.width - containerSize.width) / 2)
        let maxY = max(0, (contentSize.height - containerSize.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}
