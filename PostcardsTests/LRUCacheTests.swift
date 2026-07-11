import XCTest

final class LRUCacheTests: XCTestCase {
    func testEvictsTheLeastRecentlyUsedKeyOnceOverCapacity() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")
        cache.setValue(3, for: "c")

        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.value(for: "b"), 2)
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testReadingAKeyPromotesItSoItSurvivesLongerThanUntouchedKeys() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")
        _ = cache.value(for: "a") // promote "a" over "b"
        cache.setValue(3, for: "c")

        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertNil(cache.value(for: "b"))
    }

    func testSettingAnExistingKeyUpdatesItsValueAndRefreshesRecencyWithoutGrowingTheCache() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, for: "a")
        cache.setValue(2, for: "b")
        cache.setValue(99, for: "a") // update + refresh recency of "a"
        cache.setValue(3, for: "c") // should evict "b", not "a"

        XCTAssertEqual(cache.value(for: "a"), 99)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), 3)
    }
}
