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

    // MARK: - Progressive streaming (a collection's cards, one at a time)
    //
    // Instead of transferring a whole `.postcards` file, the phone streams a collection so the
    // first postcard shows on the watch within a second or two and the rest fill in behind it.
    // It first sends a MANIFEST (the ordered card list) so the watch can lay out every card
    // slot immediately, then sends each card's downsampled image as its own `transferFile`, in
    // scroll order. The watch buffers cards that arrive before the manifest and renders each
    // slot as its image lands.

    /// `transferUserInfo` op: the value under `manifestKey` is JSON-encoded `[WatchCardMeta]`
    /// (the collection's cards, in display order). Sent on the reliable user-info queue.
    static let opManifest = "manifest"
    static let manifestKey = "manifest"

    /// `transferFile` metadata op for one FACE of one card, at one quality tier. The file's
    /// metadata also carries `idKey` (collection id), `cardNameKey`, `cardTierKey`,
    /// `cardSideKey`, `cardIndexKey`, and `cardCountKey`.
    ///
    /// The phone does all the pixel work (splitting the stored combined image and un-rotating
    /// hand-flip backs) and sends each face as its own ready-to-display image, so the watch
    /// only ever decodes a small file — no cropping or rotation on the watch. Two tiers are
    /// sent: every card's `tierScreen` faces first (in scroll order, sized for the watch
    /// screen, so the whole collection becomes scrollable fast), then every card's `tierZoom`
    /// faces trailing behind (for double-tap zoom sharpness).
    static let opCard = "card"
    static let cardNameKey = "cardName"
    static let cardIndexKey = "cardIndex"
    static let cardCountKey = "cardCount"
    static let cardTierKey = "tier"
    static let cardSideKey = "side"
    static let tierScreen = "screen"
    static let tierZoom = "zoom"
    static let sideFront = "front"
    static let sideBack = "back"

    /// Longest-side pixel caps for the two tiers. Screen covers the largest Apple Watch
    /// display (Ultra, 410×502) with headroom; zoom is the screen tier at the 2.5× zoom level.
    static let screenTierMaxPixelSize = 512
    static let zoomTierMaxPixelSize = 1280
}

/// One card's identity + layout info, as streamed to the watch in a collection's manifest.
/// Enough to lay out the card's slot (aspect ratio, flip axis) before its image arrives.
/// `flip` reuses the shared `Flip` (see `Models.swift`).
struct WatchCardMeta: Identifiable, Hashable, Codable, Sendable {
    var id: String { name }
    var name: String
    var flip: Flip
    var frontPxW: Int
    var frontPxH: Int
}

/// One collection as advertised to the watch — enough to draw the list row without the file
/// itself. `id` is the collection's stable identifier (its filename stem); it keys relay
/// messages and the on-watch cache filename alike.
struct WatchCollectionInfo: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var cardCount: Int
}
