import CoreGraphics
import Foundation

/// The wire contract between the iPhone app (`WatchConnectivityProvider`, iOS only) and the
/// watch app (`WatchLibrary`).
///
/// watchOS can't open iCloud Drive documents, so the watch never touches iCloud. Instead the
/// phone reads the iCloud Drive `.postcards` files and relays them over WatchConnectivity: a
/// lightweight catalog is pushed as the application context, and each collection the watch
/// asks for is streamed to it progressively (see "Progressive streaming" below) and cached
/// there, so it opens with no phone present.
///
/// Two kinds of channel carry the stream. The reliable queues (`transferUserInfo`,
/// `transferFile`) survive either app being suspended, but deliver when the system sees fit,
/// in FIFO order — so anything queued earlier (another collection's backlog) holds them up.
/// Messages (`sendMessage`) arrive within a second or so, but only while both apps are
/// running and in range, and each is capped at 64KB. So what the person is looking at right
/// now — the manifest of the collection they've opened, its first cards, a card they've
/// scrolled ahead to or zoomed into — goes as messages when it can, and everything else
/// through the queues. A message that fails always falls back to the queue: messages are only
/// ever a speed-up, never the sole route for anything.
enum WatchRelay {
    // MARK: - Catalog

    /// `updateApplicationContext` key whose value is the JSON-encoded `[WatchCollectionInfo]`
    /// catalog. Application context is latest-wins and replaces any previous value, so the
    /// watch always sees the current library even if it missed intermediate updates.
    static let catalogKey = "catalog"
    /// Application-context key given a fresh value whenever the watch has asked for the
    /// catalog (`opHello`), so the context differs from the last one pushed and is delivered
    /// again even if the catalog itself hasn't changed. The watch never reads it.
    static let catalogNonceKey = "catalogNonce"

    // MARK: - Watch → phone ops

    /// Message / user-info dictionary keys for the ops either side sends.
    static let opKey = "op"
    static let idKey = "id"

    /// "I've never received a catalog." Sent as a message, which wakes the iPhone app in the
    /// background even if it hasn't been opened since it was installed — so it can publish its
    /// catalog without the person having to open it.
    static let opHello = "hello"
    /// Stream this collection to me: whatever of it I'm missing, per the `WatchDownloadRequest`
    /// JSON under `downloadRequestKey`.
    static let opRequest = "request"
    /// An older spelling of `opRequest`; the phone still honours it.
    static let opPin = "pin"
    /// Stop keeping this collection downloaded. Informational: there's nothing on the phone to
    /// cancel, as anything still arriving for it just becomes evictable on the watch.
    static let opUnpin = "unpin"
    /// Send one card's faces at one tier right now, as messages — for the card on screen that
    /// the queue hasn't reached yet (`tierScreen`), or that's just been zoomed into
    /// (`tierZoom`). Carries `cardNameKey`, `cardTierKey`, and optionally `cardSideKey` for the
    /// side that's showing, which goes first.
    static let opFocus = "focus"
    /// `opRequest` key whose value is JSON-encoded `WatchDownloadRequest`. A request without
    /// one means "I have nothing; send everything".
    static let downloadRequestKey = "downloadRequest"

    // MARK: - Progressive streaming (a collection's cards, one at a time)
    //
    // Instead of transferring a whole `.postcards` file, the phone streams a collection so the
    // first postcard shows on the watch within a second or two and the rest fill in behind it.
    // It first sends a MANIFEST (the ordered card list) so the watch can lay out every card
    // slot immediately, then each card's downsampled faces, in scroll order, then — for a
    // pinned collection — the sharper zoom tier. The watch renders each slot as its faces land.

    /// Phone → watch: the value under `manifestKey` is JSON-encoded `[WatchCardMeta]` (the
    /// collection's cards, in display order). Sent as a message when the watch is reachable,
    /// otherwise (or if the message fails) on the reliable user-info queue.
    static let opManifest = "manifest"
    static let manifestKey = "manifest"

    /// Phone → watch: one FACE of one card, at one quality tier — as a file transfer, or as
    /// messages (see "Blobs as messages"). Its metadata carries `idKey` (collection id),
    /// `cardNameKey`, `cardTierKey`, `cardSideKey`, `cardIndexKey`, and `cardCountKey`.
    ///
    /// The phone does all the pixel work (splitting the stored combined image and un-rotating
    /// hand-flip backs) and sends each face as its own ready-to-display image, so the watch
    /// only ever decodes a small file — no cropping or rotation on the watch. Two tiers exist:
    /// `tierScreen`, sized for the watch screen, sent for every card; and `tierZoom`, for
    /// double-tap zoom sharpness, sent for every card of a pinned collection (behind all the
    /// screen faces) and otherwise only for a card as it's zoomed into (`opFocus`).
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

    /// Phone → watch: a JSON-encoded `[WatchCardDetails]` blob for the whole collection — what
    /// the watch's postcard info page shows. Sent just after the first cards, like a card face
    /// (as messages when the watch is reachable, otherwise as a file transfer); its metadata
    /// carries `idKey`.
    static let opDetails = "details"

    /// Longest-side pixel caps for the two tiers. Screen covers the largest Apple Watch display
    /// (Ultra-sized, about 420×510) with headroom. Zoom matches the cap the web format itself
    /// puts on stored faces (`defaultMaxSide` in dotpostcard's `formats/resize.go`), so a
    /// zoomed card shows every pixel the collection holds.
    static let screenTierMaxPixelSize = 512
    static let zoomTierMaxPixelSize = 1536

    /// HEIC quality for the screen tier — matches the previous implicit system default, now
    /// made explicit.
    static let screenTierQuality: CGFloat = 0.8
    /// HEIC quality for the zoom tier — near-lossless, since sharpness under a double-tap
    /// zoom is the whole reason this tier exists; visible compression artifacts there would
    /// defeat it.
    static let zoomTierQuality: CGFloat = 0.95

    // MARK: - Blobs as messages

    /// A card face or details blob sent as messages rather than as a file carries the same
    /// metadata as its file transfer would, plus its bytes under `blobKey`. A blob larger than
    /// one message is split into `chunkCountKey` chunks sharing one `blobIDKey`, sent in order,
    /// each acknowledged before the next goes (see `WatchMessageChunks`).
    static let blobKey = "blob"
    static let blobIDKey = "blobID"
    static let chunkIndexKey = "chunkIndex"
    static let chunkCountKey = "chunkCount"

    /// Bytes of blob per message. WatchConnectivity rejects a message over 65,536 bytes (not
    /// documented, but consistently reported) — this leaves plenty of room for the metadata
    /// and the property-list encoding around each chunk.
    static let messageChunkSize = 48 * 1024

    /// How many of a request's missing cards go as messages, ahead of the queue.
    static let immediateCardCount = 2
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

/// What the watch asks for when it (re)requests a collection: the cards it already holds at
/// each tier, whether it already has the collection's details, and whether it wants every
/// card's zoom tier up front (a pinned collection, kept for offline use) or will ask for zoom
/// faces card by card as they're zoomed into (`WatchRelay.opFocus`). Lets a resumed or
/// repeated request send only what's missing, rather than the whole collection again.
struct WatchDownloadRequest: Codable, Equatable, Sendable {
    var haveScreen: Set<String> = []
    var haveZoom: Set<String> = []
    var haveDetails = false
    var wantsZoom = true

    /// What a request with no `WatchRelay.downloadRequestKey` means: nothing held, so send
    /// everything.
    static let everything = WatchDownloadRequest()
}

/// The phone's plan for answering one `WatchDownloadRequest`, in send order: the first
/// missing cards as messages, the details, the rest of the missing screen faces through the
/// queue, then any zoom faces behind them all.
struct WatchStreamPlan: Equatable, Sendable {
    /// Cards whose screen faces go as messages, ahead of the queue — the first ones missing,
    /// so the watch has something to show within a second or two.
    var immediateScreenCards: [String]
    /// Every other card missing its screen faces, queued in display order.
    var queuedScreenCards: [String]
    /// Whether to send the collection's details.
    var sendsDetails: Bool
    /// Cards whose zoom faces to queue, behind every screen face.
    var queuedZoomCards: [String]

    /// - Parameters:
    ///   - cardNames: the collection's cards, in display order.
    ///   - immediateLimit: how many cards may go as messages — 0 when the watch isn't
    ///     reachable, since messages can't get through.
    init(cardNames: [String], request: WatchDownloadRequest, immediateLimit: Int) {
        let missingScreen = cardNames.filter { !request.haveScreen.contains($0) }
        let immediateCount = min(max(immediateLimit, 0), missingScreen.count)
        immediateScreenCards = Array(missingScreen.prefix(immediateCount))
        queuedScreenCards = Array(missingScreen.dropFirst(immediateCount))
        sendsDetails = !request.haveDetails
        queuedZoomCards = request.wantsZoom ? cardNames.filter { !request.haveZoom.contains($0) } : []
    }
}

/// One card's information for the watch's info page: what `CardInfoPanel` shows, flattened
/// to plain strings (transcriptions lose their annotation markup, which a watch has no room to
/// render anyway). Sent for a whole collection at once, as one `WatchRelay.opDetails` blob.
struct WatchCardDetails: Codable, Hashable, Sendable {
    var name: String
    var sentOn: PostcardDate?
    var senderName: String?
    var recipientName: String?
    var locationName: String?
    var countryCode: String?
    var latitude: Double?
    var longitude: Double?
    var frontTranscription: String?
    var backTranscription: String?
    var frontDescription: String?
    var backDescription: String?
    var collectorName: String?
    var notes: String?

    /// The card's location in the shape `LocationDisplay`/`CountryFlags` expect.
    var location: Location {
        Location(name: locationName, latitude: latitude, longitude: longitude, countryCode: countryCode)
    }
}

extension WatchCardDetails {
    /// Built from a card's summary (always to hand) and, when it could be read, its full
    /// metadata — which adds the transcriptions, descriptions, and cataloguing context, and
    /// wins for the fields both carry. Blank strings become `nil`, so the watch can decide
    /// what to show by presence alone.
    init(summary: CardSummary, metadata: PostcardMetadata?) {
        // Coordinates only ever travel as a pair: half of one is no place at all.
        let latitude = metadata?.location.latitude ?? summary.latitude
        let longitude = metadata?.location.longitude ?? summary.longitude
        let hasCoordinates = latitude != nil && longitude != nil

        self.init(
            name: summary.name,
            sentOn: metadata?.sentOn ?? summary.sentOn,
            senderName: Self.nonBlank(metadata?.sender.name) ?? Self.nonBlank(summary.senderName),
            recipientName: Self.nonBlank(metadata?.recipient.name) ?? Self.nonBlank(summary.recipientName),
            locationName: Self.nonBlank(metadata?.location.name) ?? Self.nonBlank(summary.locationName),
            countryCode: Self.nonBlank(metadata?.location.countryCode) ?? Self.nonBlank(summary.countryCode),
            latitude: hasCoordinates ? latitude : nil,
            longitude: hasCoordinates ? longitude : nil,
            frontTranscription: Self.nonBlank(metadata?.front.transcription.text),
            backTranscription: Self.nonBlank(metadata?.back.transcription.text),
            frontDescription: Self.nonBlank(metadata?.front.description),
            backDescription: Self.nonBlank(metadata?.back.description),
            collectorName: Self.nonBlank(metadata?.context.author.name),
            notes: Self.nonBlank(metadata?.context.description)
        )
    }

    private static func nonBlank(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
