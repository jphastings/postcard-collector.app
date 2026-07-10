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

    // MARK: - Temporary cache eviction

    /// How many *temporary* (unpinned) cached collections to keep. Live-browsing an unpinned
    /// collection (Phase 2) caches its file just like pinning does, so without a cap the
    /// cache would grow unboundedly as someone browses their library. Pinned collections
    /// aren't subject to this cap.
    static let temporaryCacheLimit = 8

    /// Which cached collections should be evicted to bring the temporary cache back within
    /// `limit`, given each cached id's file modification date and the currently pinned set.
    /// Pinned ids are never returned; among the rest, the least-recently-modified ones beyond
    /// `limit` are (LRU). Pure decision logic — actually deleting the files is `WatchLibrary`'s job.
    static func idsToEvict(
        cachedModificationDates: [String: Date],
        pinned: Set<String>,
        limit: Int = temporaryCacheLimit
    ) -> Set<String> {
        let temporary = cachedModificationDates
            .filter { !pinned.contains($0.key) }
            .sorted { $0.value < $1.value }
        guard temporary.count > limit else { return [] }
        return Set(temporary.prefix(temporary.count - limit).map(\.key))
    }
}
