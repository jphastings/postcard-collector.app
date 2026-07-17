import XCTest

final class LocationSearchNamingTests: XCTestCase {
    func testLocalityAndCountryCompose() {
        XCTAssertEqual(
            LocationSearchNaming.displayName(locality: "Turin", administrativeArea: "Piedmont", country: "Italy", fallbackTitle: "Turin"),
            "Turin, Italy"
        )
    }

    func testMissingLocalityFallsBackToAdministrativeArea() {
        XCTAssertEqual(
            LocationSearchNaming.displayName(locality: nil, administrativeArea: "Piedmont", country: "Italy", fallbackTitle: "Piedmont"),
            "Piedmont, Italy"
        )
    }

    func testCountryOnlyWhenNeitherLocalityNorAreaKnown() {
        XCTAssertEqual(
            LocationSearchNaming.displayName(locality: nil, administrativeArea: nil, country: "Italy", fallbackTitle: "Italy"),
            "Italy"
        )
    }

    func testLocalityOnlyWhenCountryUnknown() {
        XCTAssertEqual(
            LocationSearchNaming.displayName(locality: "Turin", administrativeArea: nil, country: nil, fallbackTitle: "Turin"),
            "Turin"
        )
    }

    func testFallsBackToCompletionTitleWhenPlacemarkHasNothingUsable() {
        XCTAssertEqual(
            LocationSearchNaming.displayName(locality: nil, administrativeArea: nil, country: nil, fallbackTitle: "Eiffel Tower"),
            "Eiffel Tower"
        )
    }

    func testBlankStringFieldsAreTreatedAsMissing() {
        XCTAssertEqual(
            LocationSearchNaming.displayName(locality: "   ", administrativeArea: nil, country: "Italy", fallbackTitle: "Italy"),
            "Italy"
        )
    }

    func testLocalityPreferredOverAdministrativeAreaWhenBothPresent() {
        XCTAssertEqual(
            LocationSearchNaming.displayName(locality: "Turin", administrativeArea: "Piedmont", country: "Italy", fallbackTitle: "Turin"),
            "Turin, Italy"
        )
    }
}
