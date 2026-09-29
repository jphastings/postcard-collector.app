import Foundation

/// How the watch's collection list groups and orders the iPhone's catalog: collections
/// already on the watch — or pinned to be kept there — first, then everything that's only on
/// the iPhone. Pure, so it's unit-testable; `WatchCollectionListView` just renders it.
struct WatchCollectionSections: Equatable {
    /// On the watch (any of it cached) or pinned: pinned first, as they're kept for good
    /// while the rest may be evicted, then each group by title.
    var onWatch: [WatchCollectionInfo]
    /// Only on the iPhone, by title.
    var onPhone: [WatchCollectionInfo]

    init(catalog: [WatchCollectionInfo], pinned: Set<String>, isOnWatch: (String) -> Bool) {
        let byTitle: (WatchCollectionInfo, WatchCollectionInfo) -> Bool = {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let pinnedCollections = catalog.filter { pinned.contains($0.id) }
        let unpinned = catalog.filter { !pinned.contains($0.id) }
        onWatch = pinnedCollections.sorted(by: byTitle) + unpinned.filter { isOnWatch($0.id) }.sorted(by: byTitle)
        onPhone = unpinned.filter { !isOnWatch($0.id) }.sorted(by: byTitle)
    }
}
