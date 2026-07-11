import XCTest

final class SearchTokenTests: XCTestCase {
    // MARK: - pillLabel

    func testPillLabelsMatchTagVocabulary() {
        XCTAssertEqual(SearchToken(kind: .from, display: "Claire", value: "Claire").pillLabel, "From Claire")
        XCTAssertEqual(SearchToken(kind: .to, display: "Claire", value: "Claire").pillLabel, "To Claire")
        XCTAssertEqual(SearchToken(kind: .with, display: "Claire", value: "Claire").pillLabel, "With Claire")
        XCTAssertEqual(SearchToken(kind: .collector, display: "Claire", value: "Claire").pillLabel, "Collected by Claire")
        XCTAssertEqual(SearchToken(kind: .country, display: "Spain", value: "ESP").pillLabel, "Country Spain")
        XCTAssertEqual(SearchToken(kind: .on, display: "2024-05", value: "2024-05").pillLabel, "On 2024-05")
        XCTAssertEqual(SearchToken(kind: .before, display: "2019", value: "2019").pillLabel, "Before 2019")
        XCTAssertEqual(SearchToken(kind: .after, display: "2024", value: "2024").pillLabel, "After 2024")
    }

    // MARK: - SearchQuery.from(tokens:freeText:)

    func testPersonTokensFoldIntoTheirArrays() {
        let tokens = [
            SearchToken(kind: .from, display: "Claire", value: "mailto:claire@example.com"),
            SearchToken(kind: .to, display: "Bob", value: "Bob"),
            SearchToken(kind: .with, display: "Ana", value: "Ana"),
            SearchToken(kind: .collector, display: "Sam", value: "Sam"),
        ]
        let query = SearchQuery.from(tokens: tokens, freeText: "beach")
        XCTAssertEqual(query.text, "beach")
        XCTAssertEqual(query.from, ["mailto:claire@example.com"])
        XCTAssertEqual(query.to, ["Bob"])
        XCTAssertEqual(query.with, ["Ana"])
        XCTAssertEqual(query.collector, ["Sam"])
    }

    func testCountryTokenAppendsItsAlreadyNormalisedValue() {
        let query = SearchQuery.from(tokens: [SearchToken(kind: .country, display: "Spain", value: "ESP")], freeText: "")
        XCTAssertEqual(query.country, ["ESP"])
    }

    func testDateTokenReusesTheSameTighteningAsParse() {
        let query = SearchQuery.from(tokens: [SearchToken(kind: .on, display: "2024", value: "2024")], freeText: "")
        XCTAssertEqual(query.sentFrom, "2024-01-01")
        XCTAssertEqual(query.sentUntil, "2025-01-01")
    }

    func testTokensAndTypedTagsInFreeTextBothApply() {
        let query = SearchQuery.from(tokens: [SearchToken(kind: .from, display: "Claire", value: "Claire")], freeText: "to:Bob")
        XCTAssertEqual(query.from, ["Claire"])
        XCTAssertEqual(query.to, ["Bob"])
    }

    // MARK: - Promotion: complete vs. mid-typing

    func testCompleteTagFollowedBySpaceIsPromoted() {
        let (tokens, remainder) = SearchToken.promote(from: "from:Claire ")
        XCTAssertEqual(tokens, [SearchToken(kind: .from, display: "Claire", value: "Claire")])
        XCTAssertEqual(remainder, "")
    }

    func testTrailingTagWithNoFollowingSpaceIsNotPromoted() {
        let (tokens, remainder) = SearchToken.promote(from: "from:Clai")
        XCTAssertTrue(tokens.isEmpty)
        XCTAssertEqual(remainder, "from:Clai")
    }

    func testEarlierCompleteTagPromotesEvenWhileALaterWordIsMidTyping() {
        let (tokens, remainder) = SearchToken.promote(from: "from:Claire beach")
        XCTAssertEqual(tokens, [SearchToken(kind: .from, display: "Claire", value: "Claire")])
        XCTAssertEqual(remainder, "beach")
    }

    func testQuotedValueWithSpacesPromotesAsOneToken() {
        let (tokens, remainder) = SearchToken.promote(from: "from:\"Claire Smith\" ")
        XCTAssertEqual(tokens, [SearchToken(kind: .from, display: "Claire Smith", value: "Claire Smith")])
        XCTAssertEqual(remainder, "")
    }

    func testInvalidDateStaysInRemainderText() {
        let (tokens, remainder) = SearchToken.promote(from: "on:notadate ")
        XCTAssertTrue(tokens.isEmpty)
        XCTAssertEqual(remainder, "on:notadate")
    }

    func testValidDatePromotesWithRawTextAsBothDisplayAndValue() {
        let (tokens, _) = SearchToken.promote(from: "on:2024-05 ")
        XCTAssertEqual(tokens, [SearchToken(kind: .on, display: "2024-05", value: "2024-05")])
    }

    // The resolved display name is asserted by round-tripping it back through
    // `normalisedCountryCode` (rather than hardcoding "Spain"), so this passes under any
    // device locale.
    func testCountryPromotesToAlpha3ValueWithResolvedDisplayName() {
        let (tokens, _) = SearchToken.promote(from: "country:Spain ")
        let token = tokens.first
        XCTAssertEqual(token?.value, "ESP")
        XCTAssertEqual(token.map { SearchQuery.normalisedCountryCode($0.display) }, "ESP")
    }

    // Asserts the display resolved to SOME localized name (not just the raw code echoed
    // back) rather than hardcoding "Spain", so this passes under any device locale.
    func testCountryCodeResolvesToACountryNameDisplay() {
        let (tokens, _) = SearchToken.promote(from: "country:ESP ")
        XCTAssertEqual(tokens.first?.value, "ESP")
        XCTAssertNotEqual(tokens.first?.display, "ESP")
    }

    func testPlainTextWithNoTagsIsUntouched() {
        let (tokens, remainder) = SearchToken.promote(from: "sunset beach")
        XCTAssertTrue(tokens.isEmpty)
        XCTAssertEqual(remainder, "sunset beach")
    }
}
