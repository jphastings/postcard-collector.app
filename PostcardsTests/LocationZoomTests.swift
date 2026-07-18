import MapKit
import XCTest

final class LocationZoomTests: XCTestCase {
    // MARK: - spanMeters

    func testThoroughfareImpliesStreetScaleZoom() {
        XCTAssertEqual(
            LocationZoom.spanMeters(hasThoroughfare: true, hasLocality: false, hasAdministrativeArea: false),
            4_000
        )
    }

    func testLocalityWithoutThoroughfareImpliesCityScaleZoom() {
        XCTAssertEqual(
            LocationZoom.spanMeters(hasThoroughfare: false, hasLocality: true, hasAdministrativeArea: false),
            40_000
        )
    }

    func testAdministrativeAreaAloneImpliesRegionScaleZoom() {
        XCTAssertEqual(
            LocationZoom.spanMeters(hasThoroughfare: false, hasLocality: false, hasAdministrativeArea: true),
            300_000
        )
    }

    func testNothingResolvedImpliesContinentalZoom() {
        XCTAssertEqual(
            LocationZoom.spanMeters(hasThoroughfare: false, hasLocality: false, hasAdministrativeArea: false),
            1_500_000
        )
    }

    func testThoroughfareTakesPrecedenceOverCoarserFields() {
        XCTAssertEqual(
            LocationZoom.spanMeters(hasThoroughfare: true, hasLocality: true, hasAdministrativeArea: true),
            4_000
        )
    }

    func testLocalityTakesPrecedenceOverAdministrativeArea() {
        XCTAssertEqual(
            LocationZoom.spanMeters(hasThoroughfare: false, hasLocality: true, hasAdministrativeArea: true),
            40_000
        )
    }

    // MARK: - isSaneBoundingSpan

    func testCityScaleSpanIsSane() {
        XCTAssertTrue(LocationZoom.isSaneBoundingSpan(MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4)))
    }

    func testCountryScaleSpanIsSane() {
        XCTAssertTrue(LocationZoom.isSaneBoundingSpan(MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 40)))
    }

    func testWholeWorldFallbackSpanIsNotSane() {
        // MapKit's documented `boundingRegion` fallback when a match has no natural bounding box.
        XCTAssertFalse(LocationZoom.isSaneBoundingSpan(MKCoordinateSpan(latitudeDelta: 180, longitudeDelta: 360)))
    }

    func testZeroSpanIsNotSane() {
        XCTAssertFalse(LocationZoom.isSaneBoundingSpan(MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0)))
    }

    func testNegativeSpanIsNotSane() {
        XCTAssertFalse(LocationZoom.isSaneBoundingSpan(MKCoordinateSpan(latitudeDelta: -1, longitudeDelta: 1)))
    }

    func testNonFiniteSpanIsNotSane() {
        XCTAssertFalse(LocationZoom.isSaneBoundingSpan(MKCoordinateSpan(latitudeDelta: .nan, longitudeDelta: 1)))
    }
}
