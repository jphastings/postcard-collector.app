import XCTest

final class WatchCollectionSectionsTests: XCTestCase {
    private func info(
        _ id: String, _ title: String, isLocal: Bool? = nil, atmosphere: WatchCollectionInfo.AtmosphereRole? = nil
    ) -> WatchCollectionInfo {
        WatchCollectionInfo(id: id, title: title, cardCount: 1, atmosphere: atmosphere, isLocal: isLocal)
    }

    private func layout(_ catalog: [WatchCollectionInfo]) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: WatchCollectionSection.sections(of: catalog).map { ($0.title, $0.collections.map(\.id)) })
    }

    func testCollectionsAreGroupedAsOnTheIPhoneEachByTitle() {
        let catalog = [
            info("z", "Zanzibar"),
            info("af", "Athens", atmosphere: .followed),
            info("lk", "Kyoto", isLocal: true),
            info("b", "Berlin"),
            info("az", "Zurich", atmosphere: .own),
            info("la", "Amsterdam", isLocal: true),
            info("ab", "Bern", atmosphere: .own),
        ]

        XCTAssertEqual(WatchCollectionSection.sections(of: catalog).map(\.title), ["From iPhone", "iCloud", "Atmosphere"])
        XCTAssertEqual(layout(catalog), [
            "From iPhone": ["la", "lk"],
            "iCloud": ["b", "z"],
            "Atmosphere": ["ab", "az", "af"],
        ])
    }

    func testAnEntryFromAnOlderPhoneIsICloud() throws {
        let decoded = try JSONDecoder().decode([WatchCollectionInfo].self, from: Data(#"[{"id":"k","title":"Kyoto","cardCount":3}]"#.utf8))

        XCTAssertEqual(layout(decoded), ["iCloud": ["k"]])
    }

    func testTitlesSortNaturally() {
        let catalog = [info("10", "Trip 10"), info("2", "Trip 2"), info("1", "trip 1")]

        XCTAssertEqual(layout(catalog), ["iCloud": ["1", "2", "10"]])
    }

    func testEmptySectionsAreLeftOut() {
        XCTAssertEqual(WatchCollectionSection.sections(of: []), [])
        XCTAssertEqual(WatchCollectionSection.sections(of: [info("l", "Lisbon", isLocal: true)]).map(\.title), ["From iPhone"])
    }
}
