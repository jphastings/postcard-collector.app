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

        XCTAssertEqual(padding.top, 16) // margin only — nothing obstructs vertically in this regime
        XCTAssertEqual(padding.bottom, 16)
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
        let narrowBetweenButtons = EdgeInsets(top: 16, leading: 68, bottom: 16, trailing: 68)
        let narrowBelowBand = EdgeInsets(top: 60, leading: 16, bottom: 60, trailing: 16)
        XCTAssertGreaterThanOrEqual(fittedHeight(narrowPadding, narrow), fittedHeight(narrowBetweenButtons, narrow))
        XCTAssertGreaterThanOrEqual(fittedHeight(narrowPadding, narrow), fittedHeight(narrowBelowBand, narrow))

        let wideBetweenButtons = EdgeInsets(top: 16, leading: 68, bottom: 16, trailing: 68)
        let wideBelowBand = EdgeInsets(top: 60, leading: 16, bottom: 60, trailing: 16)
        XCTAssertGreaterThanOrEqual(fittedHeight(widePadding, wide), fittedHeight(wideBetweenButtons, wide))
        XCTAssertGreaterThanOrEqual(fittedHeight(widePadding, wide), fittedHeight(wideBelowBand, wide))
    }

    // MARK: - Leading/trailing insets (e.g. macOS's `.inspector`, reported as a trailing
    // safe-area inset on the pane rather than shrinking its frame — see `CardFitGeometry`'s
    // doc comment): every regime adds them on top of its own margin/clearance, never in place
    // of it, and the card's centre must land in the pane MINUS the inset, not the whole pane.

    func testTrailingInsetAddsToBelowBandPadding() {
        let bounding = CGSize(width: 500, height: 300) // wins below-band, per testWideLandscapeCardWinsBelowTheBand
        let padding = CardFitGeometry.atRestPadding(
            paneSize: pane, boundingSize: bounding, toolbar: toolbar, bottomInset: 0, trailingInset: 320
        )

        XCTAssertEqual(padding.leading, 16, "no leading inset supplied, so leading padding is unaffected")
        XCTAssertEqual(padding.trailing, 16 + 320, "trailing inset layers on top of the regime's own margin")
        XCTAssertEqual(padding.top, toolbar.bandHeight + 16, "vertical padding is untouched by a horizontal inset")
    }

    func testTrailingInsetAddsToBetweenButtonsPadding() {
        let bounding = CGSize(width: 300, height: 500) // wins between-buttons, per testNarrowPortraitCardWinsBetweenButtons
        let padding = CardFitGeometry.atRestPadding(
            paneSize: pane, boundingSize: bounding, toolbar: toolbar, bottomInset: 0, trailingInset: 320
        )

        XCTAssertEqual(padding.leading, toolbar.trailingWidth + 16)
        XCTAssertEqual(padding.trailing, toolbar.trailingWidth + 16 + 320)
    }

    func testTrailingInsetAddsToOpaqueBelowBandPadding() {
        var opaqueToolbar = toolbar
        opaqueToolbar.isTransparent = false
        let padding = CardFitGeometry.atRestPadding(
            paneSize: pane, boundingSize: CGSize(width: 500, height: 300), toolbar: opaqueToolbar,
            bottomInset: 20, trailingInset: 320
        )

        XCTAssertEqual(padding.leading, 16)
        XCTAssertEqual(padding.trailing, 16 + 320)
    }

    func testCardCentresInThePaneMinusTheTrailingInsetNotTheWholePane() {
        // A wide pane with a wide inspector-shaped trailing inset, and a card small enough
        // that its at-rest size is fixed by the margin alone (not by clamping against the
        // available space) — isolates the centring math from the fit-scale comparison.
        let widePane = CGSize(width: 1_200, height: 600)
        let bounding = CGSize(width: 100, height: 60)
        let trailingInset: CGFloat = 300

        let padding = CardFitGeometry.atRestPadding(
            paneSize: widePane, boundingSize: bounding, toolbar: toolbar, bottomInset: 0, trailingInset: trailingInset
        )

        let visibleRegionCenter = (widePane.width - trailingInset) / 2
        let paddedBoxCenter = padding.leading + (widePane.width - padding.leading - padding.trailing) / 2
        XCTAssertEqual(paddedBoxCenter, visibleRegionCenter, accuracy: 0.001)
        XCTAssertNotEqual(paddedBoxCenter, widePane.width / 2, "must not centre in the full pane, under the inspector")
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

    // MARK: - Invariant: the at-rest card never touches a pane edge, in any regime

    func testEveryRegimeKeepsAtLeastAMarginOnAllFourSides() {
        let margin: CGFloat = 16
        let leadingInset: CGFloat = 40
        let trailingInset: CGFloat = 40
        let bottomInset: CGFloat = 20

        var opaqueToolbar = toolbar
        opaqueToolbar.isTransparent = false

        let scenarios: [(name: String, bounding: CGSize, toolbar: ToolbarGeometry)] = [
            ("between-buttons", CGSize(width: 300, height: 500), toolbar),
            ("below-band, transparent", CGSize(width: 500, height: 300), toolbar),
            ("below-band, opaque", CGSize(width: 500, height: 300), opaqueToolbar),
        ]

        for scenario in scenarios {
            let padding = CardFitGeometry.atRestPadding(
                paneSize: pane, boundingSize: scenario.bounding, toolbar: scenario.toolbar,
                bottomInset: bottomInset, leadingInset: leadingInset, trailingInset: trailingInset, margin: margin
            )
            XCTAssertGreaterThanOrEqual(padding.top, margin, "\(scenario.name): top must clear the margin")
            XCTAssertGreaterThanOrEqual(padding.bottom, margin, "\(scenario.name): bottom must clear the margin")
            XCTAssertGreaterThanOrEqual(
                padding.leading, margin + leadingInset, "\(scenario.name): leading must clear the margin + inset"
            )
            XCTAssertGreaterThanOrEqual(
                padding.trailing, margin + trailingInset, "\(scenario.name): trailing must clear the margin + inset"
            )
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
