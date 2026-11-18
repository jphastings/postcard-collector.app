import CryptoKit
import Foundation

/// Pure construction of the watch catalog's `WatchCollectionInfo` entries — from a `CloudItem`
/// and (if already downloaded) a `CollectionReader` open on it, or from a downloaded Atmosphere
/// collection — and the reverse: which file a watch request's id names. Kept free of
/// `WatchConnectivity` — unlike `WatchConnectivityProvider` (iOS only) — so it compiles and is
/// testable on every platform.
enum WatchCatalogBuilder {
    /// Builds one catalog entry. Pass `reader: nil` for anything not yet `.current` — the
    /// phone must never force a download just to populate the catalog — which yields an
    /// entry with only the display name and no count; it gets enriched the next time the
    /// catalog is rebuilt after the item finishes downloading.
    static func entry(for item: CloudItem, reader: CollectionReader?) -> WatchCollectionInfo {
        guard let reader else {
            return WatchCollectionInfo(id: item.displayName, title: item.displayName, cardCount: 0)
        }

        let cardCount = (try? reader.cardCount()) ?? 0
        let title = (try? reader.title()) ?? item.displayName

        return WatchCollectionInfo(id: item.displayName, title: title, cardCount: cardCount)
    }

    static func entry(for collection: DownloadedAtmosphereCollection) -> WatchCollectionInfo {
        WatchCollectionInfo(
            id: atmosphereID(uri: collection.uri),
            title: collection.title,
            cardCount: collection.cardCount,
            atmosphere: collection.isFollowed ? .followed : .own
        )
    }

    /// An Atmosphere collection's catalog id, from its at-uri: hashed, because the watch names a
    /// directory after every id and an at-uri has slashes in it (and can outgrow a filename).
    /// The prefix keeps it from looking like any plausible iCloud filename.
    static func atmosphereID(uri: String) -> String {
        "atproto-" + SHA256.hash(data: Data(uri.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The collection file a watch request's `id` names, or `nil` if it names none (yet).
    static func path(forID id: String, cloudItems: [CloudItem], atmosphere: [DownloadedAtmosphereCollection]) -> String? {
        atmosphere.first { atmosphereID(uri: $0.uri) == id }?.path
            ?? cloudItems.first { $0.isCollection && $0.displayName == id }?.path
    }
}
