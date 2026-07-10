import Foundation

/// The wire contract between the iPhone app (`WatchConnectivityProvider`, iOS only) and the
/// watch app (`WatchLibrary`).
///
/// watchOS can't open iCloud Drive documents, so the watch never touches iCloud. Instead the
/// phone reads the iCloud Drive `.postcards` files and relays them over WatchConnectivity:
/// a lightweight catalog is pushed as the application context, and a pinned collection's
/// whole file is sent with `transferFile` and cached on the watch so it opens with no phone
/// present.
enum WatchRelay {
    /// `updateApplicationContext` key whose value is the JSON-encoded `[WatchCollectionInfo]`
    /// catalog. Application context is latest-wins and replaces any previous value, so the
    /// watch always sees the current library even if it missed intermediate updates.
    static let catalogKey = "catalog"

    /// Message / user-info dictionary keys for the ops the watch sends the phone.
    static let opKey = "op"
    static let idKey = "id"

    /// Please transfer this collection's file so it can be kept downloaded on the watch.
    static let opPin = "pin"
    /// Stop keeping this collection downloaded (the phone can drop any queued resend).
    static let opUnpin = "unpin"
    /// Send this (unpinned) collection now, for immediate viewing while reachable (Phase 2).
    static let opRequest = "request"

    /// `transferFile` metadata key carrying the `WatchCollectionInfo.id` of the file being sent,
    /// so the watch knows which catalog entry a received file belongs to.
    static let fileIdKey = "id"
}

/// One collection as advertised to the watch — enough to draw the list row without the file
/// itself. `id` is the collection's stable identifier (its filename stem); it keys relay
/// messages and the on-watch cache filename alike.
struct WatchCollectionInfo: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var cardCount: Int
    /// A small pre-rendered cover thumbnail (JPEG/PNG bytes) for the list row, or `nil` if the
    /// phone hasn't been able to read the collection's file yet.
    var coverThumbnail: Data?
}
