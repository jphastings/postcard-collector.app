import XCTest

final class MasonryLayoutTests: XCTestCase {
    private struct Item: Equatable {
        var name: String
        /// width / height — matches how the views feed `CardSummary.frontPxW/H` in.
        var aspectRatio: Double
    }

    private func distribute(_ items: [Item], count: Int) -> [[Item]] {
        MasonryLayout.columns(of: items, count: count, aspectRatio: \.aspectRatio)
    }

    private func columnHeights(_ columns: [[Item]]) -> [Double] {
        // Mirrors the documented item-height rule (1/ratio, non-positive ratios = square).
        columns.map { $0.reduce(0) { $0 + ($1.aspectRatio > 0 ? 1 / $1.aspectRatio : 1) } }
    }

    // MARK: - Distribution

    func testEmptyInputYieldsEmptyColumns() {
        let columns = distribute([], count: 3)
        XCTAssertEqual(columns.count, 3)
        XCTAssertTrue(columns.allSatisfy(\.isEmpty))
    }

    func testSingleItemLandsInTheFirstColumn() {
        let item = Item(name: "only", aspectRatio: 1.5)
        let columns = distribute([item], count: 3)
        XCTAssertEqual(columns[0], [item])
        XCTAssertTrue(columns[1].isEmpty)
        XCTAssertTrue(columns[2].isEmpty)
    }

    func testEveryItemIsPlacedExactlyOnce() {
        let items = (0..<25).map { Item(name: "card-\($0)", aspectRatio: Double($0 % 5 + 1) / 3) }
        let columns = distribute(items, count: 4)
        XCTAssertEqual(columns.flatMap { $0 }.count, items.count)
        XCTAssertEqual(Set(columns.flatMap { $0 }.map(\.name)).count, items.count)
    }

    func testGreedyBalanceBound() {
        // Classic property of shortest-column-first: no column overshoots the shortest by
        // more than one item, so max − min ≤ the tallest single item's height.
        let items = (0..<40).map { Item(name: "card-\($0)", aspectRatio: [0.5, 0.75, 1.0, 1.5, 2.0][$0 % 5]) }
        let columns = distribute(items, count: 3)
        let heights = columnHeights(columns)
        let tallestItem = items.map { 1 / $0.aspectRatio }.max()!

        XCTAssertLessThanOrEqual(heights.max()! - heights.min()!, tallestItem + 0.0001)
    }

    func testDistributionIsDeterministic() {
        let items = (0..<30).map { Item(name: "card-\($0)", aspectRatio: Double(($0 * 7) % 11 + 1) / 4) }
        let first = distribute(items, count: 4)
        let second = distribute(items, count: 4)
        XCTAssertEqual(first, second)
    }

    func testTiesGoToTheLeftmostColumn() {
        // Equal-height columns at every step: strict round-robin left to right.
        let items = (0..<4).map { Item(name: "card-\($0)", aspectRatio: 1) }
        let columns = distribute(items, count: 2)
        XCTAssertEqual(columns[0].map(\.name), ["card-0", "card-2"])
        XCTAssertEqual(columns[1].map(\.name), ["card-1", "card-3"])
    }

    func testNonPositiveAspectRatioIsTreatedAsSquareNotInfinity() {
        let items = [Item(name: "broken", aspectRatio: 0), Item(name: "fine", aspectRatio: 1)]
        let columns = distribute(items, count: 2)
        XCTAssertEqual(columns.flatMap { $0 }.count, 2)
        XCTAssertTrue(columnHeights(columns).allSatisfy(\.isFinite))
    }

    // MARK: - Column count adaptation

    func testNarrowPhoneWidthStillGetsTwoColumns() {
        // ~iPhone portrait content width: one 180pt column would "fit", but the floor is 2.
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 343), 2)
    }

    func testColumnCountGrowsWithWidth() {
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 380), 2)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 600), 3)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 800), 4)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 1200), 6)
    }

    func testDegenerateWidthFallsBackToTheMinimum() {
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: 0), 2)
        XCTAssertEqual(MasonryLayout.columnCount(forAvailableWidth: -100), 2)
    }
}
