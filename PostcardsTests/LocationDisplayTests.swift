import XCTest

/// Regression coverage for the bug where `CardInfoPanel` briefly showed a Map carried over
/// from the previous card (fixed in `CardDetailView.load()` by resetting `metadata` — see
/// that file). This locks in the actual display decision: a map only ever renders when
/// BOTH coordinates are present.
final class LocationDisplayTests: XCTestCase {
    func testNoNameNoCoordinatesShowsNothing() {
        let location = Location(name: nil, latitude: nil, longitude: nil, countryCode: nil)
        XCTAssertFalse(LocationDisplay.showsSection(for: location))
        XCTAssertFalse(LocationDisplay.hasCoordinates(location))
    }

    func testNameOnlyShowsSectionButNoMap() {
        let location = Location(name: "Somewhere", latitude: nil, longitude: nil, countryCode: nil)
        XCTAssertTrue(LocationDisplay.showsSection(for: location))
        XCTAssertFalse(LocationDisplay.hasCoordinates(location))
    }

    func testCoordinatesOnlyShowsSectionAndMap() {
        let location = Location(name: nil, latitude: 48.8566, longitude: 2.3522, countryCode: nil)
        XCTAssertTrue(LocationDisplay.showsSection(for: location))
        XCTAssertTrue(LocationDisplay.hasCoordinates(location))
    }

    func testOnlyLatitudeIsNotEnoughForAMap() {
        let location = Location(name: nil, latitude: 48.8566, longitude: nil, countryCode: nil)
        XCTAssertFalse(LocationDisplay.hasCoordinates(location))
    }

    func testOnlyLongitudeIsNotEnoughForAMap() {
        let location = Location(name: nil, latitude: nil, longitude: 2.3522, countryCode: nil)
        XCTAssertFalse(LocationDisplay.hasCoordinates(location))
    }

    func testNameAndCoordinatesShowsBoth() {
        let location = Location(name: "Paris, France", latitude: 48.8566, longitude: 2.3522, countryCode: "FRA")
        XCTAssertTrue(LocationDisplay.showsSection(for: location))
        XCTAssertTrue(LocationDisplay.hasCoordinates(location))
    }
}
