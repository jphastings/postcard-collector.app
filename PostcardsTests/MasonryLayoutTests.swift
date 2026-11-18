import XCTest

final class MasonryLayoutTests: XCTestCase {
    private struct Item: Equatable {
        var name: String
        /// width / height — matches how the views feed `CardSummary.frontPxW/H` in.
        var aspectRatio: Double
    }

    private func place(_ items: [Item], width: Double = 400, count: Int, spacing: Double = 16) -> MasonryLayout.Placement {
        MasonryLayout.placement(of: items, width: width, columnCount: count, spacing: spacing, aspectRatio: \.aspectRatio)
    }

    /// Item names per column, left to right, top to bottom — read back from the frames.
    private func columns(_ items: [Item], count: Int) -> [[String]] {
        let frames = place(items, count: count).frames
        let xs = Set(frames.map(\.minX)).sorted()
        return (0..<count).map { column in
            items.indices
                .filter { column < xs.count && frames[$0].minX == xs[column] }
                .sorted { frames[$0].minY < frames[$1].minY }
                .map { items[$0].name }
        }
    }

    private let mixed = (0..<40).map { Item(name: "card-\($0)", aspectRatio: [0.5, 0.75, 1.0, 1.5, 2.0][$0 % 5]) }

    // MARK: - Placement

    func testEmptyInputHasNoHeight() {
        let placement = place([], count: 3)
        XCTAssertTrue(placement.frames.isEmpty)
        XCTAssertEqual(placement.contentHeight, 0)
    }

    func testHeightsComeFromAspectRatiosAtColumnWidth() {
        // 400pt across two columns with 16pt between: 192pt columns.
        let placement = place([Item(name: "wide", aspectRatio: 2), Item(name: "tall", aspectRatio: 0.5)], count: 2)
        XCTAssertEqual(placement.frames, [
            CGRect(x: 0, y: 0, width: 192, height: 96),
            CGRect(x: 208, y: 0, width: 192, height: 384),
        ])
    }

    func testEachItemGoesUnderTheShortestColumn() {
        let items = [Item(name: "a", aspectRatio: 2), Item(name: "b", aspectRatio: 0.5), Item(name: "c", aspectRatio: 1), Item(name: "d", aspectRatio: 1)]
        XCTAssertEqual(columns(items, count: 2), [["a", "c", "d"], ["b"]])
        let frames = place(items, count: 2).frames
        XCTAssertEqual(frames[2].minY, frames[0].maxY + 16)
        XCTAssertEqual(frames[3].minY, frames[2].maxY + 16)
    }

    func testTiesGoToTheLeftmostColumn() {
        let items = (0..<4).map { Item(name: "card-\($0)", aspectRatio: 1) }
        XCTAssertEqual(columns(items, count: 2), [["card-0", "card-2"], ["card-1", "card-3"]])
    }

    func testFramesNeverOverlap() {
        let frames = place(mixed, count: 3).frames
        for i in frames.indices {
            for j in frames.indices where i < j {
                XCTAssertFalse(frames[i].intersects(frames[j]), "\(i) and \(j)")
            }
        }
    }

    func testContentHeightIsTheTallestColumnsBottom() {
        let placement = place(mixed, count: 3)
        XCTAssertEqual(placement.contentHeight, placement.frames.map(\.maxY).max()!, accuracy: 0.0001)
    }

    func testColumnsStayBalanced() {
        // Shortest-column-first: no column ends more than one item (and its spacing) below another.
        let frames = place(mixed, count: 3).frames
        let bottoms = Dictionary(grouping: frames, by: \.minX).values.map { $0.map(\.maxY).max()! }
        let tallestItem = frames.map(\.height).max()!
        XCTAssertLessThanOrEqual(bottoms.max()! - bottoms.min()!, tallestItem + 16 + 0.0001)
    }

    func testAppendingItemsLeavesExistingFramesInPlace() {
        let before = place(Array(mixed.prefix(25)), count: 3).frames
        let after = place(mixed, count: 3).frames
        XCTAssertEqual(Array(after.prefix(25)), before)
    }

    func testPlacementIsDeterministic() {
        XCTAssertEqual(place(mixed, count: 4), place(mixed, count: 4))
    }

    func testNonPositiveAspectRatioIsTreatedAsSquare() {
        let placement = place([Item(name: "broken", aspectRatio: 0), Item(name: "fine", aspectRatio: -1)], count: 2)
        XCTAssertEqual(placement.frames.map(\.height), [192, 192])
    }

    // MARK: - Render span

    func testRenderSpanCoversTheScreenAndAViewportEitherSide() {
        for offset in stride(from: -100.0, through: 3000, by: 37) {
            let span = MasonryLayout.renderSpan(scrollOffset: offset, viewportHeight: 800)
            XCTAssertLessThanOrEqual(span.lowerBound, offset - 800)
            XCTAssertGreaterThanOrEqual(span.upperBound, offset + 1600)
        }
    }

    func testRenderSpanHoldsStillThroughSmallScrolls() {
        XCTAssertEqual(
            MasonryLayout.renderSpan(scrollOffset: 410, viewportHeight: 800),
            MasonryLayout.renderSpan(scrollOffset: 790, viewportHeight: 800)
        )
    }

    // MARK: - Column count adaptation

    func testNarrowPhoneWidthStillGetsTwoColumns() {
        // ~iPhone portrait content width: below the 180pt-per-column target but above the
        // 150pt-per-column minimum, so it holds at two columns.
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 343), 2)
    }

    func testVeryNarrowPanesDropToASingleColumn() {
        // Two columns need 2×150 + 16 = 316pt; anything under that gets one full-width
        // column, exactly at the boundary two.
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 315.9), 1)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 316), 2)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 200), 1)
    }

    func testColumnCountGrowsWithWidth() {
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 380), 2)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 600), 3)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 800), 4)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 1200), 6)
    }

    func testDegenerateWidthFallsBackToASingleColumn() {
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 0), 1)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: -100), 1)
    }
}
