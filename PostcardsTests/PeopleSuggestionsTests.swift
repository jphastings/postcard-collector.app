import XCTest

final class PeopleSuggestionsTests: XCTestCase {
    private let claire = PersonRef(name: "Claire Smith", uri: "https://claire.example", roles: ["from", "to"])
    private let sam = PersonRef(name: "Sam", uri: nil, roles: ["collector"])
    private let clara = PersonRef(name: "Clara Jones", uri: "https://clara.example", roles: ["to"])

    func testEmptyQueryMatchesNothing() {
        XCTAssertTrue(PeopleSuggestions.matches(for: "", in: [claire], preferringRole: "from").isEmpty)
        XCTAssertTrue(PeopleSuggestions.matches(for: "   ", in: [claire], preferringRole: "from").isEmpty)
    }

    func testMatchesNameStartCaseAndDiacriticInsensitively() {
        let esme = PersonRef(name: "Èsme", uri: nil, roles: ["from"])
        XCTAssertEqual(PeopleSuggestions.matches(for: "esm", in: [esme], preferringRole: "from"), [esme])
        XCTAssertEqual(PeopleSuggestions.matches(for: "CLA", in: [claire], preferringRole: "from"), [claire])
    }

    func testMatchesALaterWordPrefix() {
        XCTAssertEqual(PeopleSuggestions.matches(for: "smi", in: [claire], preferringRole: "from"), [claire])
    }

    func testNonMatchingQueryReturnsEmpty() {
        XCTAssertTrue(PeopleSuggestions.matches(for: "xyz", in: [claire], preferringRole: "from").isEmpty)
    }

    // MARK: - Ranking: preferred role first, then match quality

    func testPreferredRoleOutranksMatchQualityEvenAsAWordStartMatch() {
        let preferredWordStart = PersonRef(name: "Anna Clara", uri: nil, roles: ["from"])
        let nonPreferredNameStart = PersonRef(name: "Clara Jones", uri: nil, roles: ["to"])

        let results = PeopleSuggestions.matches(for: "clara", in: [nonPreferredNameStart, preferredWordStart], preferringRole: "from")

        XCTAssertEqual(results.first, preferredWordStart, "senders-first ranks above match quality for a From field")
    }

    func testNameStartOutranksWordStartWithinTheSameRolePreferenceGroup() {
        let nameStart = PersonRef(name: "Clara Jones", uri: nil, roles: ["from"])
        let wordStart = PersonRef(name: "Anna Clara", uri: nil, roles: ["from"])

        let results = PeopleSuggestions.matches(for: "clara", in: [wordStart, nameStart], preferringRole: "from")

        XCTAssertEqual(results, [nameStart, wordStart])
    }

    func testPreferringRoleNeverExcludesNonMatchingRolePeople() {
        let results = PeopleSuggestions.matches(for: "sam", in: [sam], preferringRole: "from")
        XCTAssertEqual(results, [sam], "collector-only Sam still appears when preferring 'from'")
    }

    func testTiedRoleAndQualityFallBackToAlphabeticalName() {
        let results = PeopleSuggestions.matches(for: "cla", in: [claire, clara], preferringRole: "to")
        XCTAssertEqual(Set(results), Set([claire, clara]), "both hold 'to', both name-start match")
        XCTAssertEqual(results.first, claire, "\"Claire\" < \"Clara\" alphabetically once role and quality tie")
    }

    // MARK: - Edge cases

    func testSelectingIgnoresPeopleWithNoName() {
        let anonymous = PersonRef(name: nil, uri: "https://anon.example", roles: ["from"])
        XCTAssertTrue(PeopleSuggestions.matches(for: "any", in: [anonymous], preferringRole: "from").isEmpty)
    }

    func testLimitCapsResultCount() {
        let people = (0..<10).map { PersonRef(name: "Clara \($0)", uri: nil, roles: ["to"]) }
        XCTAssertEqual(PeopleSuggestions.matches(for: "clara", in: people, preferringRole: "to", limit: 3).count, 3)
    }

    func testTiedMatchesFallBackToAlphabeticalNameThenURI() {
        let a1 = PersonRef(name: "Clara", uri: "https://a.example", roles: [])
        let a2 = PersonRef(name: "Clara", uri: "https://b.example", roles: [])
        let results = PeopleSuggestions.matches(for: "clara", in: [a2, a1], preferringRole: "from")
        XCTAssertEqual(results, [a1, a2])
    }
}
