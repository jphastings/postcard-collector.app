import Foundation

/// Pure, synchronous helpers for the watch's on-disk pin cache and catalog persistence —
/// factored out of `WatchLibrary` so they're testable without WatchConnectivity or the
/// `@MainActor` isolation the rest of that class needs.
enum WatchCacheLayout {
    /// The filename a pinned collection's file is cached under. Matches the `id` (a
    /// collection's filename stem) the phone tags its `transferFile` metadata with.
    static func cacheFileName(for id: String) -> String { "\(id).postcards" }

    static func pinnedCollectionsDirectory(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("PinnedCollections", isDirectory: true)
    }

    static func cacheURL(for id: String, in supportDirectory: URL) -> URL {
        pinnedCollectionsDirectory(in: supportDirectory).appendingPathComponent(cacheFileName(for: id))
    }

    static func catalogFileURL(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("watch-catalog.json")
    }

    static func encodeCatalog(_ catalog: [WatchCollectionInfo]) -> Data? {
        try? JSONEncoder().encode(catalog)
    }

    static func decodeCatalog(_ data: Data) -> [WatchCollectionInfo]? {
        try? JSONDecoder().decode([WatchCollectionInfo].self, from: data)
    }
}
