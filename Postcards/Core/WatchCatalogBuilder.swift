import Foundation

/// Pure construction of a `WatchCollectionInfo` catalog entry from a `CloudItem` and (if
/// already downloaded) a `CollectionReader` open on it. Kept free of `WatchConnectivity` —
/// unlike `WatchConnectivityProvider` (iOS only) — so it compiles and is testable on every
/// platform.
enum WatchCatalogBuilder {
    /// Builds one catalog entry. Pass `reader: nil` for anything not yet `.current` — the
    /// phone must never force a download just to populate the catalog — which yields an
    /// entry with only the display name and no count; it gets enriched the next time the
    /// catalog is rebuilt after the item finishes downloading.
    static func entry(for item: CloudItem, reader: CollectionReader?) -> WatchCollectionInfo {
        guard let reader else {
            return WatchCollectionInfo(id: item.displayName, title: item.displayName, cardCount: 0)
        }

        let summaries = (try? reader.cardSummaries()) ?? []
        let title = (try? reader.title()) ?? item.displayName

        return WatchCollectionInfo(id: item.displayName, title: title, cardCount: summaries.count)
    }
}
