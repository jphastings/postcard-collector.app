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

    func testKnownAlpha2CodesConvertToAlpha3() {
        XCTAssertEqual(CountryFlags.alpha3(forAlpha2: "US"), "USA")
        XCTAssertEqual(CountryFlags.alpha3(forAlpha2: "gb"), "GBR", "lookup should be case-insensitive")
        XCTAssertEqual(CountryFlags.alpha3(forAlpha2: "IT"), "ITA")
    }

    func testUnknownAlpha2CodeReturnsNil() {
        XCTAssertNil(CountryFlags.alpha3(forAlpha2: "ZZ"))
    }
}
