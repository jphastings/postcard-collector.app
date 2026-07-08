import XCTest

final class PinStoreTests: XCTestCase {
    private func makeEphemeralDefaults() -> UserDefaults {
        let suiteName = "PinStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testCollectionsAreUnpinnedByDefault() {
        let store = PinStore(defaults: makeEphemeralDefaults())
        XCTAssertFalse(store.isPinned("Trip to Kyoto"))
        XCTAssertTrue(store.pinnedKeys.isEmpty)
    }

    func testSetPinnedTruePinsAndFalseUnpins() {
        let store = PinStore(defaults: makeEphemeralDefaults())

        store.setPinned(true, for: "Trip to Kyoto")
        XCTAssertTrue(store.isPinned("Trip to Kyoto"))
        XCTAssertEqual(store.pinnedKeys, ["Trip to Kyoto"])

        store.setPinned(false, for: "Trip to Kyoto")
        XCTAssertFalse(store.isPinned("Trip to Kyoto"))
        XCTAssertTrue(store.pinnedKeys.isEmpty)
    }

    func testMultipleCollectionsPinIndependently() {
        let store = PinStore(defaults: makeEphemeralDefaults())

        store.setPinned(true, for: "Trip to Kyoto")
        store.setPinned(true, for: "Postcards from Rome")
        store.setPinned(false, for: "Trip to Kyoto")

        XCTAssertFalse(store.isPinned("Trip to Kyoto"))
        XCTAssertTrue(store.isPinned("Postcards from Rome"))
    }

    func testPinsPersistAcrossAFreshPinStoreOnTheSameSuite() {
        let defaults = makeEphemeralDefaults()
        PinStore(defaults: defaults).setPinned(true, for: "Trip to Kyoto")

        let reopened = PinStore(defaults: defaults)
        XCTAssertTrue(reopened.isPinned("Trip to Kyoto"))
    }
}
