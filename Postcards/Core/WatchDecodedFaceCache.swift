import CoreGraphics
import Foundation
import ImageIO

/// A minimal least-recently-used cache: `value(for:)` promotes the key to most-recently-used,
/// `setValue(_:for:)` evicts the least-recently-used entry once `capacity` is exceeded. Pure
/// in-memory bookkeeping — no I/O — so it's fully unit-testable with any `Hashable` key.
struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = [] // oldest first

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    mutating func setValue(_ value: Value, for key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            storage[order.removeFirst()] = nil
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Removes every key matching `shouldRemove` from both the backing storage and the
    /// recency order, so a removed key can't be resurrected by later LRU bookkeeping.
    mutating func removeValues(where shouldRemove: (Key) -> Bool) {
        for key in order where shouldRemove(key) {
            storage[key] = nil
        }
        order.removeAll(where: shouldRemove)
    }
}

/// Decodes a face image at most once, keyed by which collection/card/tier/side it is, so
/// `WatchPostcardScrollView`'s `LazyVStack` recycling a recently-shown card doesn't redecode
/// it — capacity is small (a dozen-ish faces) since the watch only ever needs the handful of
/// cards around the current scroll position decoded at once. An `actor` rather than a
/// `@MainActor` type: decode happens off the main actor here for free, and callers (SwiftUI
/// views) just `await` it.
actor WatchDecodedFaceCache {
    private var cache: LRUCache<WatchFaceKey, CGImage>

    init(capacity: Int = 12) {
        cache = LRUCache(capacity: capacity)
    }

    /// `nil` if the file is missing, corrupt, or not an image — never a crash. Never
    /// resizes/crops/rotates: every face the phone sends is already ready to display.
    func decodedFace(_ key: WatchFaceKey, at url: URL) -> CGImage? {
        if let cached = cache.value(for: key) { return cached }
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            )
        else { return nil }
        cache.setValue(image, for: key)
        return image
    }

    /// Drops every decoded face belonging to `collectionID` — called when its download is
    /// removed outright, so a stale decoded image can't outlive the blob it was decoded from.
    func invalidate(collectionID: String) {
        cache.removeValues { $0.id == collectionID }
    }
}
