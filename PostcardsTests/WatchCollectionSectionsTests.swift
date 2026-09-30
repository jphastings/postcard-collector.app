import XCTest

final class WatchCollectionSectionsTests: XCTestCase {
    private func info(_ id: String, _ title: String) -> WatchCollectionInfo {
        WatchCollectionInfo(id: id, title: title, cardCount: 1)
    }

    func testDownloadedCollectionsComeFirstThenTheRestByTitle() {
        let catalog = [info("z", "Zanzibar"), info("k", "Kyoto"), info("b", "Berlin"), info("a", "Athens")]

        let sections = WatchCollectionSections(catalog: catalog, pinned: [], isOnWatch: { $0 == "z" || $0 == "b" })

        XCTAssertEqual(sections.onWatch.map(\.id), ["b", "z"])
        XCTAssertEqual(sections.onPhone.map(\.id), ["a", "k"])
    }

    func testPinnedCollectionsLeadTheDownloadedOnesEvenBeforeTheyveArrived() {
        let catalog = [info("a", "Athens"), info("b", "Berlin"), info("k", "Kyoto")]

        // Kyoto is pinned but hasn't downloaded yet; Athens is downloaded but not pinned.
        let sections = WatchCollectionSections(catalog: catalog, pinned: ["k"], isOnWatch: { $0 == "a" })

        XCTAssertEqual(sections.onWatch.map(\.id), ["k", "a"])
        XCTAssertEqual(sections.onPhone.map(\.id), ["b"])
    }

    func testTitlesSortNaturally() {
        let catalog = [info("10", "Trip 10"), info("2", "Trip 2"), info("1", "trip 1")]

        let sections = WatchCollectionSections(catalog: catalog, pinned: [], isOnWatch: { _ in false })

        XCTAssertEqual(sections.onPhone.map(\.id), ["1", "2", "10"])
    }

    func testAnEmptyCatalogHasEmptySections() {
        let sections = WatchCollectionSections(catalog: [], pinned: ["gone"], isOnWatch: { _ in true })

        XCTAssertEqual(sections.onWatch, [])
        XCTAssertEqual(sections.onPhone, [])
    }
}
