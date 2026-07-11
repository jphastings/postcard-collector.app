import SwiftUI
import XCTest

final class CardFitGeometryTests: XCTestCase {
    private let pane = CGSize(width: 800, height: 600)
    // bandHeight 44, trailing (i) button cluster 52pt, no leading cluster (macOS-shaped).
    private let toolbar = ToolbarGeometry(bandHeight: 44, leadingWidth: 0, trailingWidth: 52, isTransparent: true)

    // MARK: - Transparent toolbar: regime selection picks the larger card

    func testNarrowPortraitCardWinsBetweenButtons() {
        // Tall and narrow enough that ducking between the clusters (full pane height) fits a
        // bigger card than centring below the band would.
        let bounding = CGSize(width: 300, height: 500)
        let padding = CardFitGeometry.atRestPadding(paneSize: pane, boundingSize: bounding, toolbar: toolbar, bottomInset: 0)

        XCTAssertEqual(padding.top, 0)
        XCTAssertEqual(padding.bottom, 0)
        XCTAssertEqual(padding.leading, toolbar.trailingWidth + 16) // max(leading, trailing) + margin
        XCTAssertEqual(padding.trailing, toolbar.trailingWidth + 16)
    }

    func testWideLandscapeCardWinsBelowTheBand() {
        // Wide enough that the full pane width (below the band) beats squeezing between the
        // clusters.
        let bounding = CGSize(width: 500, height: 300)
        let padding = CardFitGeometry.atRestPadding(paneSize: pane, boundingSize: bounding, toolbar: toolbar, bottomInset: 0)

        XCTAssertEqual(padding.top, toolbar.bandHeight + 16)
        XCTAssertEqual(padding.bottom, toolbar.bandHeight + 16) // symmetric: centred in the whole pane
        XCTAssertEqual(padding.leading, 16)
        XCTAssertEqual(padding.trailing, 16)
    }

    func testWinningRegimeIsWhicheverFitsTheBiggerCard() {
        let narrow = CGSize(width: 300, height: 500)
        let wide = CGSize(width: 500, height: 300)

        let narrowPadding = CardFitGeometry.atRestPadding(paneSize: pane, boundingSize: narrow, toolbar: toolbar, bottomInset: 0)
        let widePadding = CardFitGeometry.atRestPadding(paneSize: pane, boundingSize: wide, toolbar: toolbar, bottomInset: 0)

        func fittedHeight(_ padding: EdgeInsets, _ bounding: CGSize) -> CGFloat {
            let availableWidth = pane.width - padding.leading - padding.trailing
            let availableHeight = pane.height - padding.top - padding.bottom
            let scale = min(availableWidth / bounding.width, availableHeight / bounding.height)
            return bounding.height * scale
        }

        // Each card's own winning regime must never be smaller than the OTHER regime would
        // have made it — that's the whole point of comparing scales.
        let narrowBetweenButtons = EdgeInsets(top: 0, leading: 68, bottom: 0, trailing: 68)
        let narrowBelowBand = EdgeInsets(top: 60, leading: 16, bottom: 60, trailing: 16)
        XCTAssertGreaterThanOrEqual(fittedHeight(narrowPadding, narrow), fittedHeight(narrowBetweenButtons, narrow))
        XCTAssertGreaterThanOrEqual(fittedHeight(narrowPadding, narrow), fittedHeight(narrowBelowBand, narrow))

        let wideBetweenButtons = EdgeInsets(top: 0, leading: 68, bottom: 0, trailing: 68)
        let wideBelowBand = EdgeInsets(top: 60, leading: 16, bottom: 60, trailing: 16)
        XCTAssertGreaterThanOrEqual(fittedHeight(widePadding, wide), fittedHeight(wideBetweenButtons, wide))
        XCTAssertGreaterThanOrEqual(fittedHeight(widePadding, wide), fittedHeight(wideBelowBand, wide))
    }

    // MARK: - Opaque toolbar: only ever below the band, regardless of card shape

    func testOpaqueToolbarNeverLetsTheCardIntersectTheBand() {
        var opaqueToolbar = toolbar
        opaqueToolbar.isTransparent = false

        for bounding in [CGSize(width: 300, height: 500), CGSize(width: 500, height: 300)] {
            let padding = CardFitGeometry.atRestPadding(
                paneSize: pane, boundingSize: bounding, toolbar: opaqueToolbar, bottomInset: 20
            )

            // Always the below-band formula: top clears the band, bottom clears the home
            // indicator/safe area — never the between-buttons regime's zero top padding.
            XCTAssertEqual(padding.top, opaqueToolbar.bandHeight + 16)
            XCTAssertEqual(padding.bottom, 20 + 16)
            XCTAssertEqual(padding.leading, 16)
            XCTAssertEqual(padding.trailing, 16)
            XCTAssertGreaterThanOrEqual(padding.top, opaqueToolbar.bandHeight, "card must clear the opaque bar")
        }
    }

    // MARK: - Degenerate sizes

    func testZeroPaneSizeFallsBackSafelyWithoutCrashingOrProducingNaN() {
        let padding = CardFitGeometry.atRestPadding(
            paneSize: .zero, boundingSize: CGSize(width: 300, height: 500), toolbar: toolbar, bottomInset: 0
        )
        for value in [padding.top, padding.leading, padding.bottom, padding.trailing] {
            XCTAssertFalse(value.isNaN)
            XCTAssertGreaterThanOrEqual(value, 0)
        }
    }

    func testZeroBoundingSizeFallsBackSafely() {
        let padding = CardFitGeometry.atRestPadding(
            paneSize: pane, boundingSize: .zero, toolbar: toolbar, bottomInset: 0
        )
        XCTAssertEqual(padding, CardFitGeometry.atRestPadding(paneSize: pane, boundingSize: .zero, toolbar: {
            var opaque = toolbar
            opaque.isTransparent = false
            return opaque
        }(), bottomInset: 0), "degenerate input falls back to the same safe below-band padding regardless of transparency")
    }

    func testNegativeSizesDoNotCrashOrProduceNegativePadding() {
        let padding = CardFitGeometry.atRestPadding(
            paneSize: CGSize(width: -100, height: 600),
            boundingSize: CGSize(width: 300, height: 500),
            toolbar: toolbar,
            bottomInset: 0
        )
        for value in [padding.top, padding.leading, padding.bottom, padding.trailing] {
            XCTAssertFalse(value.isNaN)
            XCTAssertGreaterThanOrEqual(value, 0)
        }
    }
}
