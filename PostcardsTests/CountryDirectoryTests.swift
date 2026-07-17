import XCTest

final class CountryDirectoryTests: XCTestCase {
    // Fixed locale, not `.current` — assertions on exact display strings would be flaky
    // depending on the test machine's locale.
    private let entries = CountryDirectory.makeEntries(locale: Locale(identifier: "en_US"))

    func testEveryCountryIsIncluded() {
        XCTAssertEqual(entries.count, CountryFlags.alpha3ToAlpha2.count)
    }

    func testContainsUnitedStatesWithFlag() {
        let usa = entries.first { $0.alpha3 == "USA" }
        XCTAssertEqual(usa?.displayName, "United States")
        XCTAssertEqual(usa?.flag, CountryFlags.flag(forAlpha3: "USA"))
        XCTAssertNotNil(usa?.flag)
    }

    func testContainsUnitedKingdomWithFlag() {
        let gbr = entries.first { $0.alpha3 == "GBR" }
        XCTAssertEqual(gbr?.displayName, "United Kingdom")
        XCTAssertEqual(gbr?.flag, CountryFlags.flag(forAlpha3: "GBR"))
        XCTAssertNotNil(gbr?.flag)
    }

    func testEntriesAreSortedByDisplayName() {
        for (lhs, rhs) in zip(entries, entries.dropFirst()) {
            XCTAssertNotEqual(lhs.displayName.localizedStandardCompare(rhs.displayName), .orderedDescending)
        }
    }
}
