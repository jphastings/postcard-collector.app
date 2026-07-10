import Foundation

/// Pure, synchronous helpers for the watch's on-disk streaming cache and catalog persistence —
/// factored out of `WatchLibrary` so they're testable without WatchConnectivity or the
/// `@MainActor` isolation the rest of that class needs.
///
/// Each collection gets its own directory (rather than one flat `.postcards` file) because
/// progressive streaming fills it in incrementally: a manifest describing every card's slot,
/// then each card's downsampled image blob as it arrives — see `WatchRelay`.
enum WatchCacheLayout {
    static func collectionsDirectory(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Collections", isDirectory: true)
    }

    static func collectionDirectory(id: String, in supportDirectory: URL) -> URL {
        collectionsDirectory(in: supportDirectory).appendingPathComponent(id, isDirectory: true)
    }

    static func manifestURL(id: String, in supportDirectory: URL) -> URL {
        collectionDirectory(id: id, in: supportDirectory).appendingPathComponent("manifest.json")
    }

    static func cardsDirectory(id: String, in supportDirectory: URL) -> URL {
        collectionDirectory(id: id, in: supportDirectory).appendingPathComponent("cards", isDirectory: true)
    }

    static func cardBlobURL(id: String, cardName: String, in supportDirectory: URL) -> URL {
        cardsDirectory(id: id, in: supportDirectory).appendingPathComponent(safeCardFileName(for: cardName))
    }

    /// Maps a card's `name` (may contain spaces, punctuation, slashes) to a filesystem-safe,
    /// stable filename: base64url (no padding) of its UTF-8 bytes. Reversible by design — the
    /// original name is never needed back from disk, but the encoding stays lossless so it
    /// can't collide between two different names.
    static func safeCardFileName(for name: String) -> String {
        Data(name.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The inverse of `safeCardFileName(for:)` — used on launch to recover a card's `name`
    /// from the blob filenames already on disk (`cards/` is listed by filename, not by the
    /// `WatchCardMeta` that produced it). `nil` for anything that isn't valid base64url or
    /// UTF-8, which should only happen for a stray, non-card file in that directory.
    static func cardName(fromSafeFileName safeFileName: String) -> String? {
        var base64 = safeFileName
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingNeeded = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: paddingNeeded)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
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

    static func encodeManifest(_ manifest: [WatchCardMeta]) -> Data? {
        try? JSONEncoder().encode(manifest)
    }

    static func decodeManifest(_ data: Data) -> [WatchCardMeta]? {
        try? JSONDecoder().decode([WatchCardMeta].self, from: data)
    }

    // MARK: - Temporary cache eviction

    /// How many *temporary* (unpinned) cached collections to keep. Live-browsing an unpinned
    /// collection caches it just like pinning does, so without a cap the cache would grow
    /// unboundedly as someone browses their library. Pinned collections aren't subject to
    /// this cap.
    static let temporaryCacheLimit = 8

    /// Which cached collections should be evicted to bring the temporary cache back within
    /// `limit`, given each cached id's *directory* modification date and the currently pinned
    /// set. Pinned ids are never returned; among the rest, the least-recently-modified ones
    /// beyond `limit` are (LRU). Pure decision logic — actually deleting the directories is
    /// `WatchLibrary`'s job.
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
