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

    /// Clamps a pan offset so content scaled by `scale` about its own center inside a
    /// `containerSize`-sized viewport can never be dragged far enough to open a gap at any
    /// edge — the bound on each axis is half the scaled overhang, `(scale - 1) * size / 2`.
    /// Unlike `CardDetailView`'s free-panning pinch zoom, the watch's double-tap zoom
    /// (`WatchCardView`) needs its pan clamped, since it sits inside a snap-scrolling list
    /// that only disables paging while zoomed — an unclamped drag could otherwise shove the
    /// whole card out of view with no way back short of the zoom-reset gesture.
    static func clampedOffset(_ offset: CGSize, scale: CGFloat, containerSize: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maxX = containerSize.width * (scale - 1) / 2
        let maxY = containerSize.height * (scale - 1) / 2
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}
