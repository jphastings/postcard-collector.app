import XCTest

final class SearchSuggestionsTests: XCTestCase {
    private let claire = PersonRef(name: "Claire", uri: "https://claire.example", roles: ["from", "to"])
    private let sam = PersonRef(name: "Sam", uri: nil, roles: ["collector"])
    private let alexOne = PersonRef(name: "Alex", uri: "https://alex1.example", roles: ["from"])
    private let alexTwo = PersonRef(name: "Alex", uri: "https://alex2.example", roles: ["from"])

    // MARK: - Tagged fragment role filtering

    func testTaggedFragmentRestrictsToThatRoleOnly() {
        let suggestions = SearchSuggestions.suggestions(for: "from:cla", people: [claire, sam])
        XCTAssertEqual(suggestions, [SearchToken(kind: .from, display: "Claire", value: "https://claire.example")])
    }

    func testCollectorTagOnlyMatchesCollectorRolePeople() {
        let suggestions = SearchSuggestions.suggestions(for: "collector:cla", people: [claire, sam])
        XCTAssertTrue(suggestions.isEmpty, "Claire has no collector role")
    }

    func testWithTagMatchesEitherFromOrToRole() {
        let toOnly = PersonRef(name: "Bob", uri: nil, roles: ["to"])
        let suggestions = SearchSuggestions.suggestions(for: "with:bob", people: [toOnly])
        XCTAssertEqual(suggestions, [SearchToken(kind: .with, display: "Bob", value: "Bob")])
    }

    // MARK: - Plain fragment: multi-role suggestions

    func testPlainFragmentSuggestsOneTokenPerApplicableRole() {
        let suggestions = SearchSuggestions.suggestions(for: "cla", people: [claire])
        XCTAssertEqual(suggestions, [
            SearchToken(kind: .from, display: "Claire", value: "https://claire.example"),
            SearchToken(kind: .to, display: "Claire", value: "https://claire.example"),
            SearchToken(kind: .with, display: "Claire", value: "https://claire.example"),
        ])
    }

    func testPlainFragmentOnlySuggestsCollectedByForCollectorOnlyPerson() {
        // "sam" also prefixes the country name Samoa — person tokens come first, and no
        // from/to/with tokens appear for a collector-only person.
        let suggestions = SearchSuggestions.suggestions(for: "sam", people: [sam])
        XCTAssertEqual(suggestions.first, SearchToken(kind: .collector, display: "Sam", value: "Sam"))
        XCTAssertFalse(suggestions.contains { [.from, .to, .with].contains($0.kind) })
    }

    // MARK: - Value: uri vs. name

    func testPersonWithURIUsesURIAsValueNameAsDisplay() {
        let suggestions = SearchSuggestions.suggestions(for: "from:cla", people: [claire])
        XCTAssertEqual(suggestions.first?.display, "Claire")
        XCTAssertEqual(suggestions.first?.value, "https://claire.example")
    }

    func testPersonWithoutURIUsesNameAsValue() {
        let suggestions = SearchSuggestions.suggestions(for: "collector:sam", people: [sam])
        XCTAssertEqual(suggestions.first?.value, "Sam")
    }

    // MARK: - Two same-named people, distinct by uri

    func testTwoSameNamedPeopleProduceDistinctTokens() {
        let suggestions = SearchSuggestions.suggestions(for: "from:alex", people: [alexOne, alexTwo])
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(Set(suggestions.map(\.id)).count, 2, "same name, different uri => distinct token ids")
        XCTAssertEqual(Set(suggestions.map(\.value)), ["https://alex1.example", "https://alex2.example"])
    }

    // MARK: - Country suggestions

    func testTaggedCountryFragmentSuggestsMatchingCountryByCode() {
        let suggestions = SearchSuggestions.suggestions(for: "country:esp", people: [])
        XCTAssertTrue(suggestions.contains { $0.kind == .country && $0.value == "ESP" })
    }

    func testPlainFragmentCountrySuggestionsComeAfterPersonSuggestions() {
        // "Espen" is a name match AND "esp" prefixes Spain's alpha-3 code, so both a person
        // and a country suggestion are eligible from the same fragment.
        let espen = PersonRef(name: "Espen", uri: nil, roles: ["from"])
        let suggestions = SearchSuggestions.suggestions(for: "esp", people: [espen], limit: 20)

        let personIndex = suggestions.firstIndex { $0.display == "Espen" }
        let countryIndex = suggestions.firstIndex { $0.kind == .country && $0.value == "ESP" }
        XCTAssertNotNil(personIndex)
        XCTAssertNotNil(countryIndex)
        if let personIndex, let countryIndex {
            XCTAssertLessThan(personIndex, countryIndex)
        }
    }

    // MARK: - Dates: complete valid date suggests its own token

    func testCompleteValidDateFragmentSuggestsItsOwnToken() {
        let suggestions = SearchSuggestions.suggestions(for: "on:2024-05", people: [])
        XCTAssertEqual(suggestions, [SearchToken(kind: .on, display: "2024-05", value: "2024-05")])
    }

    func testIncompleteOrInvalidDateFragmentSuggestsNothing() {
        XCTAssertTrue(SearchSuggestions.suggestions(for: "on:2024-", people: []).isEmpty)
        XCTAssertTrue(SearchSuggestions.suggestions(for: "on:notadate", people: []).isEmpty)
    }

    // MARK: - Dedupe against active tokens

    func testDedupesAgainstActiveTokensByKindAndValue() {
        let existing = [SearchToken(kind: .from, display: "Claire", value: "https://claire.example")]
        let suggestions = SearchSuggestions.suggestions(for: "cla", people: [claire], existingTokens: existing)
        XCTAssertFalse(suggestions.contains { $0.kind == .from })
        XCTAssertTrue(suggestions.contains { $0.kind == .to })
        XCTAssertTrue(suggestions.contains { $0.kind == .with })
    }

    // MARK: - Trailing fragment / minimum length

    func testSingleCharacterPlainFragmentSuggestsNothing() {
        XCTAssertTrue(SearchSuggestions.suggestions(for: "c", people: [claire]).isEmpty)
    }

    func testEmptyTrailingFragmentAfterTrailingSpaceSuggestsNothing() {
        XCTAssertTrue(SearchSuggestions.suggestions(for: "from:Claire ", people: [claire]).isEmpty)
    }
}
