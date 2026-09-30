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
/// holding still.
enum ZoomGeometry {
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
