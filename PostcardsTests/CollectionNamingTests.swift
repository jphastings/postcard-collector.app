import XCTest

final class CollectionNamingTests: XCTestCase {
    func testPlainTitlePassesThrough() {
        XCTAssertEqual(CollectionNaming.filename(forTitle: "Summer Holidays"), "Summer Holidays.postcards")
    }

    func testPathSeparatorsAndColonsBecomeDashes() {
        XCTAssertEqual(CollectionNaming.filename(forTitle: "Trips/2024: Japan\\Kyoto"), "Trips-2024- Japan-Kyoto.postcards")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(CollectionNaming.filename(forTitle: "  Postcards  "), "Postcards.postcards")
    }

    func testEmptyAndWhitespaceOnlyTitlesFallBack() {
        XCTAssertEqual(CollectionNaming.filename(forTitle: ""), "Untitled.postcards")
        XCTAssertEqual(CollectionNaming.filename(forTitle: "   "), "Untitled.postcards")
    }

    func testLeadingDotsAreStrippedSoTheFileCanNeverBeHidden() {
        XCTAssertEqual(CollectionNaming.filename(forTitle: ".hidden"), "hidden.postcards")
        XCTAssertEqual(CollectionNaming.filename(forTitle: "..."), "Untitled.postcards")
    }

    func testControlCharactersAreDropped() {
        XCTAssertEqual(CollectionNaming.filename(forTitle: "A\u{0000}B\nC"), "ABC.postcards")
    }

    func testUnicodeTitlesSurvive() {
        XCTAssertEqual(CollectionNaming.filename(forTitle: "Grüße aus Berlin 🐻"), "Grüße aus Berlin 🐻.postcards")
    }
}
