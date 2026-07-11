import XCTest

final class SearchQueryTests: XCTestCase {
    // MARK: - Free text

    func testPlainTextParsesAsFreeTextOnly() {
        let query = SearchQuery.parse("beach")
        XCTAssertEqual(query.text, "beach")
        XCTAssertTrue(query.isPlainText)
    }

    func testQuotedValueWithSpacesParsesAsOneValue() {
        let query = SearchQuery.parse("from:\"Claire Smith\"")
        XCTAssertEqual(query.from, ["Claire Smith"])
        XCTAssertEqual(query.text, "")
        XCTAssertFalse(query.isPlainText)
    }

    func testMixedFreeTextAndTag() {
        let query = SearchQuery.parse("sunset from:Claire")
        XCTAssertEqual(query.text, "sunset")
        XCTAssertEqual(query.from, ["Claire"])
    }

    func testWithTag() {
        let query = SearchQuery.parse("with:Bob")
        XCTAssertEqual(query.with, ["Bob"])
        XCTAssertFalse(query.isPlainText)
    }

    func testUnknownTagPassesThroughAsFreeTextVerbatim() {
        let query = SearchQuery.parse("foo:bar")
        XCTAssertEqual(query.text, "foo:bar")
        XCTAssertTrue(query.isPlainText)
    }

    // MARK: - Dates: on/before/after, each of yyyy / yyyy-MM / yyyy-MM-dd

    func testOnWithYearSetsWholeYearRange() {
        let query = SearchQuery.parse("on:2024")
        XCTAssertEqual(query.sentFrom, "2024-01-01")
        XCTAssertEqual(query.sentUntil, "2025-01-01")
    }

    func testOnWithYearMonthSetsWholeMonthRangeAcrossYearRollover() {
        let query = SearchQuery.parse("on:2024-12")
        XCTAssertEqual(query.sentFrom, "2024-12-01")
        XCTAssertEqual(query.sentUntil, "2025-01-01")
    }

    func testOnWithFullDateSetsSingleDayRange() {
        let query = SearchQuery.parse("on:2024-03-05")
        XCTAssertEqual(query.sentFrom, "2024-03-05")
        XCTAssertEqual(query.sentUntil, "2024-03-06")
    }

    func testBeforeYear() {
        let query = SearchQuery.parse("before:2024")
        XCTAssertNil(query.sentFrom)
        XCTAssertEqual(query.sentUntil, "2024-01-01")
    }

    func testBeforeYearMonth() {
        let query = SearchQuery.parse("before:2024-03")
        XCTAssertEqual(query.sentUntil, "2024-03-01")
    }

    func testBeforeFullDate() {
        let query = SearchQuery.parse("before:2024-03-05")
        XCTAssertEqual(query.sentUntil, "2024-03-05")
    }

    func testAfterYear() {
        let query = SearchQuery.parse("after:2024")
        XCTAssertEqual(query.sentFrom, "2025-01-01")
        XCTAssertNil(query.sentUntil)
    }

    func testAfterYearMonth() {
        let query = SearchQuery.parse("after:2024-03")
        XCTAssertEqual(query.sentFrom, "2024-04-01")
    }

    func testAfterFullDate() {
        let query = SearchQuery.parse("after:2024-03-05")
        XCTAssertEqual(query.sentFrom, "2024-03-06")
    }

    func testInvalidDateFallsBackToFreeTextOfWholeToken() {
        let query = SearchQuery.parse("on:notadate")
        XCTAssertEqual(query.text, "on:notadate")
        XCTAssertNil(query.sentFrom)
        XCTAssertNil(query.sentUntil)
    }

    // MARK: - Tightening

    func testTwoAfterTagsTightenToTheLaterBound() {
        let query = SearchQuery.parse("after:2024-01 after:2024-06")
        XCTAssertEqual(query.sentFrom, "2024-07-01")
    }

    func testTwoBeforeTagsTightenToTheEarlierBound() {
        let query = SearchQuery.parse("before:2024-06 before:2024-01")
        XCTAssertEqual(query.sentUntil, "2024-01-01")
    }

    func testOnThenBeforeNarrowsTheUpperBound() {
        let query = SearchQuery.parse("on:2024 before:2024-03")
        XCTAssertEqual(query.sentFrom, "2024-01-01")
        XCTAssertEqual(query.sentUntil, "2024-03-01")
    }

    // MARK: - Country normalisation

    func testCountryNameNormalisesToAlpha3() {
        XCTAssertEqual(SearchQuery.normalisedCountryCode("Spain"), "ESP")
    }

    func testCountryAlpha2NormalisesToAlpha3() {
        XCTAssertEqual(SearchQuery.normalisedCountryCode("ES"), "ESP")
    }

    func testCountryAlreadyAlpha3StaysAsIs() {
        XCTAssertEqual(SearchQuery.normalisedCountryCode("esp"), "ESP")
    }

    func testCountryTagInQueryIsNormalised() {
        let query = SearchQuery.parse("country:Spain")
        XCTAssertEqual(query.country, ["ESP"])
    }

    // MARK: - filterJSON

    func testFilterJSONRoundTripsAndContainsExpectedKeys() throws {
        let query = SearchQuery.parse("sunset from:\"Claire Smith\" country:ESP on:2024")
        let json = try XCTUnwrap(query.filterJSON)

        XCTAssertTrue(json.contains("\"text\":\"sunset\""))
        XCTAssertTrue(json.contains("\"from\":[\"Claire Smith\"]"))
        XCTAssertTrue(json.contains("\"country\":[\"ESP\"]"))
        XCTAssertTrue(json.contains("\"sent_from\":\"2024-01-01\""))
        XCTAssertTrue(json.contains("\"sent_until\":\"2025-01-01\""))

        let decoded = try JSONDecoder().decode(SearchQuery.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, query)
    }

    func testPlainQueryFilterJSONOmitsEmptyFields() throws {
        let query = SearchQuery.parse("beach")
        let json = try XCTUnwrap(query.filterJSON)

        XCTAssertFalse(json.contains("\"from\""))
        XCTAssertFalse(json.contains("\"sent_from\""))
    }
}
