import XCTest

final class CountryFlagsTests: XCTestCase {
    func testKnownAlpha3CodesProduceFlags() {
        XCTAssertEqual(CountryFlags.flag(forAlpha3: "ITA"), "🇮🇹")
        XCTAssertEqual(CountryFlags.flag(forAlpha3: "jpn"), "🇯🇵", "lookup should be case-insensitive")
        XCTAssertEqual(CountryFlags.flag(forAlpha3: "DEU"), "🇩🇪")
    }

    func testUnknownCodeReturnsNil() {
        XCTAssertNil(CountryFlags.flag(forAlpha3: "ZZZ"))
    }
}
