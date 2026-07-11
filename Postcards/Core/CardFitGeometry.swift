import SwiftUI

/// Models the window/toolbar chrome as a top button band, for `CardFitGeometry.atRestPadding`.
/// `NSToolbar`/`UINavigationBar` can't be measured directly, so `CardDetailView` estimates
/// these from platform + `@State` rather than reading real button frames.
struct ToolbarGeometry {
    /// Height of the top button band, taken from the top safe-area inset.
    var bandHeight: CGFloat
    /// Width of the leading button cluster, measured from the pane's leading edge
    /// (inclusive of any margin around the buttons).
    var leadingWidth: CGFloat
    /// Width of the trailing button cluster, measured from the pane's trailing edge.
    var trailingWidth: CGFloat
    /// Whether the toolbar's background is hidden (macOS 15+ via
    /// `transparentWindowToolbarBackground()`, and all of iOS, whose bars are translucent),
    /// so the at-rest card may rise into the band as long as it clears the button clusters.
    /// `false` only for macOS 14, whose opaque bar the card must never sit under.
    var isTransparent: Bool
}

/// At-rest sizing for `CardDetailView`'s zoomable card: how much padding to apply around the
/// card container so the aspect-fit, centred bounding box (front AND back — see
/// `FlipGeometry.boundingSize`, since the flip must never reveal a face poking out from under
/// a button) clears the toolbar's button clusters.
///
/// The toolbar is modelled as a top button band (see `ToolbarGeometry`). Three padding
/// "regimes" are considered, each expressed as the symmetric padding that keeps the centred,
/// aspect-fit card clear of the band from that regime's vantage point:
///
/// - **Between-buttons** (transparent only): the card ducks between the leading/trailing
///   clusters, so it may use the full pane height; only the horizontal clearance
///   (`max(leadingWidth, trailingWidth)`, since the card is centred and so needs identical
///   clearance on both sides) limits its width. Nothing obstructs the card vertically in this
///   regime, so no vertical margin is added — matching the previous "narrow card fills the
///   full height" behaviour this replaces.
/// - **Below-band, transparent**: the card stays clear of the band altogether by centring in
///   `paneHeight − 2×bandHeight` (symmetric, because the card is centred *in the pane*, not
///   pinned below the band) with a modest side margin.
/// - **Below-band, opaque**: the only regime an opaque bar (macOS 14) allows. The card centres
///   in the region strictly below the band, i.e. asymmetric top/bottom padding
///   (`bandHeight` vs `bottomInset`) — this is the pre-existing "safe-area insets + margin"
///   behaviour, unchanged.
///
/// For a transparent toolbar, both applicable regimes are evaluated and whichever fits the
/// bounding box at the larger scale wins — a narrow portrait card wins between-buttons (full
/// height), a wide landscape card wins below-band (full width).
enum CardFitGeometry {
    static func atRestPadding(
        paneSize: CGSize,
        boundingSize: CGSize,
        toolbar: ToolbarGeometry,
        bottomInset: CGFloat,
        margin: CGFloat = 16
    ) -> EdgeInsets {
        let belowBandOpaque = belowBandOpaquePadding(toolbar: toolbar, bottomInset: bottomInset, margin: margin)

        // Nothing meaningful to fit — fall back to the regime that never risks sitting under
        // an opaque bar, regardless of transparency.
        guard paneSize.width > 0, paneSize.height > 0, boundingSize.width > 0, boundingSize.height > 0 else {
            return belowBandOpaque
        }
        guard toolbar.isTransparent else { return belowBandOpaque }

        let betweenButtons = betweenButtonsPadding(toolbar: toolbar, margin: margin)
        let belowBandTransparent = belowBandTransparentPadding(toolbar: toolbar, margin: margin)

        let betweenButtonsScale = fitScale(paneSize: paneSize, padding: betweenButtons, boundingSize: boundingSize)
        let belowBandScale = fitScale(paneSize: paneSize, padding: belowBandTransparent, boundingSize: boundingSize)

        return betweenButtonsScale > belowBandScale ? betweenButtons : belowBandTransparent
    }

    private static func betweenButtonsPadding(toolbar: ToolbarGeometry, margin: CGFloat) -> EdgeInsets {
        let clearance = max(toolbar.leadingWidth, toolbar.trailingWidth) + margin
        return EdgeInsets(top: 0, leading: clearance, bottom: 0, trailing: clearance)
    }

    private static func belowBandTransparentPadding(toolbar: ToolbarGeometry, margin: CGFloat) -> EdgeInsets {
        let vertical = toolbar.bandHeight + margin
        return EdgeInsets(top: vertical, leading: margin, bottom: vertical, trailing: margin)
    }

    private static func belowBandOpaquePadding(toolbar: ToolbarGeometry, bottomInset: CGFloat, margin: CGFloat) -> EdgeInsets {
        EdgeInsets(top: toolbar.bandHeight + margin, leading: margin, bottom: bottomInset + margin, trailing: margin)
    }

    /// The scale an aspect-fit `boundingSize` would be drawn at inside `paneSize` once
    /// `padding` is subtracted from each edge — i.e. how "big" the card gets under this
    /// regime's padding. Zero (never the winning regime) if the padding leaves no positive
    /// space to fit into.
    private static func fitScale(paneSize: CGSize, padding: EdgeInsets, boundingSize: CGSize) -> CGFloat {
        let availableWidth = paneSize.width - padding.leading - padding.trailing
        let availableHeight = paneSize.height - padding.top - padding.bottom
        guard availableWidth > 0, availableHeight > 0 else { return 0 }
        return min(availableWidth / boundingSize.width, availableHeight / boundingSize.height)
    }
}
